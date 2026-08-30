import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Direct coverage for `CursorLocalService`'s pure slices — the summary →
/// `UsageMetrics` mapping and the JWT `sub` → userId extraction — neither of
/// which requires Cursor's SQLite DB or the dashboard API.
final class CursorLocalServiceTests: XCTestCase {

    private func decodeSummary(_ json: String) throws -> CursorUsageSummaryResponse {
        try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: Data(json.utf8))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeJWT(sub: String) -> String {
        let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
        let body = base64URL(try! JSONSerialization.data(withJSONObject: ["sub": sub]))
        return "\(header).\(body).sig"
    }

    // MARK: - Summary mapping

    func testMapSummaryUsesPlanUsageForBillingCycleLimit() throws {
        // Current /api/usage-summary shape: the quota lives in `plan.limit`
        // with the grant broken out under `plan.breakdown`.
        let json = """
        {
          "billingCycleStart": "2026-07-01T00:00:00Z",
          "billingCycleEnd": "2026-08-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": {
              "used": 137,
              "limit": 750,
              "remaining": 613,
              "breakdown": { "included": 500, "bonus": 250, "total": 750 }
            },
            "onDemand": { "used": 4, "limit": 20, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.service, .cursor)
        XCTAssertEqual(metrics.weeklyLimit?.used, 137)
        XCTAssertEqual(metrics.weeklyLimit?.total, 750)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, FlexibleISO8601.date(from: "2026-08-01T00:00:00Z"))
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 31 * 24 * 3_600)
        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.sessionLimit?.total, 20)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, false)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 31 * 24 * 3_600)
        XCTAssertNotNil(metrics.weeklyLimit?.pace(now: Date(timeIntervalSince1970: 1_783_036_800)))
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testMapSummaryFallsBackToBreakdownTotalWhenPlanLimitAbsent() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 60, "breakdown": { "included": 500, "bonus": 250, "total": 750 } }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.total, 750)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
    }

    func testMapSummaryDerivesBreakdownTotalFromIncludedAndBonus() throws {
        // `breakdown.total` omitted: included + bonus is still a server-provided
        // quota, so it must not fall through to the estimated default.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 60, "breakdown": { "included": 500, "bonus": 100 } }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.total, 600)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
    }

    func testMapSummaryIgnoresNonPositiveBreakdownParts() throws {
        // A negative or zeroed part is an absent grant, not a debit: summing it
        // would shrink the denominator below what the server actually granted.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 60, "breakdown": { "included": 500, "bonus": -100 } }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
    }

    func testMapSummaryTreatsAllNonPositiveBreakdownPartsAsAbsent() throws {
        // Nothing positive left to sum, so the estimate stands in rather than a
        // zero or negative denominator.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 60, "breakdown": { "included": 0, "bonus": -100 } }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, true)
    }

    func testMapSummaryHonorsLegacyFlatPlanTotal() throws {
        // Older payloads exposed the grant as flat `included`/`bonus`/`total`.
        let json = """
        { "individualUsage": { "plan": { "used": 137, "included": 500, "bonus": 0, "total": 500 } } }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.used, 137)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
    }

    func testMapSummarySubstitutesDefaultPlanTotalWhenMissing() throws {
        // When the API omits every quota field, the assumed monthly quota (500)
        // is used and flagged as estimated.
        let json = """
        { "individualUsage": { "plan": { "used": 50 } } }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.used, 50)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, true)
    }

    func testMapSummaryTreatsZeroQuotaFieldsAsAbsent() throws {
        // A zeroed plan block carries no usable denominator; substituting the
        // estimate beats dividing by zero.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 0, "limit": 0, "breakdown": { "included": 0, "bonus": 0, "total": 0 } }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, true)
    }

    func testMapSummaryOmitsSessionLimitWhenOnDemandDisabled() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 5, "limit": 20, "enabled": false }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertNil(metrics.sessionLimit)
    }

    func testMapSummaryUsesHeadroomEstimateWhenOnDemandLimitZero() throws {
        // enabled + used>0 but limit==0 → total falls back to used * 1.5 headroom.
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 8, "limit": 0, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertEqual(metrics.sessionLimit?.used, 8)
        XCTAssertEqual(metrics.sessionLimit?.total ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, true)
    }

    func testMapSummaryOmitsSessionLimitWhenOnDemandAllZero() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 10, "total": 500 },
            "onDemand": { "used": 0, "limit": 0, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertNil(metrics.sessionLimit)
    }

    func testMapSummaryFallsBackToTeamUsageWithServerQuota() throws {
        let json = """
        {
          "teamUsage": {
            "plan": { "used": 340, "limit": 1200, "remaining": 860 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.used, 340)
        XCTAssertEqual(metrics.weeklyLimit?.total, 1200)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, false)
    }

    func testMapSummaryEstimatesTeamQuotaWhenDenominatorMissing() throws {
        let json = """
        {
          "teamUsage": {
            "plan": { "used": 85 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.used, 85)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.weeklyLimit?.isEstimated, true)
    }

    func testMapSummaryPrefersIndividualUsageWhenBothShapesHavePlanCounters() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 40, "limit": 500 },
            "onDemand": { "used": 3, "limit": 15, "enabled": true }
          },
          "teamUsage": {
            "plan": { "used": 900, "limit": 2000 },
            "onDemand": { "used": 70, "limit": 100, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.used, 40)
        XCTAssertEqual(metrics.weeklyLimit?.total, 500)
        XCTAssertEqual(metrics.sessionLimit?.used, 3)
        XCTAssertEqual(metrics.sessionLimit?.total, 15)
    }

    func testMapSummaryUsesTeamOnDemandWithTeamPlan() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "limit": 500 },
            "onDemand": { "used": 2, "limit": 10, "enabled": true }
          },
          "teamUsage": {
            "plan": { "used": 240, "limit": 1000 },
            "onDemand": { "used": 18, "limit": 60, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.used, 240)
        XCTAssertEqual(metrics.sessionLimit?.used, 18)
        XCTAssertEqual(metrics.sessionLimit?.total, 60)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, false)
    }

    func testMapSummaryUsesAutoAndApiPercentsAsTwoIncludedPools() throws {
        let json = """
        {
          "billingCycleEnd": "2026-09-10T00:00:00Z",
          "membershipType": "ultra",
          "individualUsage": {
            "plan": {
              "used": 495,
              "limit": 500,
              "autoPercentUsed": 4,
              "apiPercentUsed": 64,
              "totalPercentUsed": 99
            },
            "onDemand": { "used": 0, "limit": 0, "enabled": false }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.sessionLimit?.total, 100)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, false)
        XCTAssertEqual(metrics.weeklyLimit?.used, 64)
        XCTAssertEqual(metrics.weeklyLimit?.total, 100)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, FlexibleISO8601.date(from: "2026-09-10T00:00:00Z"))
        XCTAssertNil(metrics.weeklyLimit?.windowSeconds, "End without start cannot invent a cycle length")
        XCTAssertNil(metrics.sessionLimit?.windowSeconds)
        XCTAssertNil(metrics.codeReviewLimit)
        XCTAssertNotEqual(metrics.overallStatus, .critical)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    /// Cursor's included pools reset with the monthly billing cycle. Both
    /// percent-of-100 pools must carry that cadence so the blocked-card
    /// headline reads "Monthly reset in Xd" instead of the raw window name.
    func testMapSummaryPercentPoolsCarryMonthlyPeriodKind() throws {
        let json = """
        {
          "billingCycleEnd": "2026-09-10T00:00:00Z",
          "individualUsage": {
            "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.sessionLimit?.periodKind, .monthly)
        XCTAssertEqual(metrics.weeklyLimit?.periodKind, .monthly)
    }

    func testMapSummaryUsesBillingCycleStartAndEndForPace() throws {
        let json = """
        {
          "billingCycleStart": "2026-08-10T00:00:00Z",
          "billingCycleEnd": "2026-09-10T00:00:00Z",
          "individualUsage": {
            "plan": {
              "autoPercentUsed": 30,
              "apiPercentUsed": 100
            },
            "onDemand": { "used": 2, "limit": 10, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        let expectedWindow = 31 * 24 * 3_600.0
        let reset = FlexibleISO8601.date(from: "2026-09-10T00:00:00Z")

        XCTAssertEqual(metrics.sessionLimit?.resetTime, reset)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, reset)
        XCTAssertEqual(metrics.codeReviewLimit?.resetTime, reset)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, expectedWindow)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, expectedWindow)
        XCTAssertEqual(metrics.codeReviewLimit?.windowSeconds, expectedWindow)

        let start = try XCTUnwrap(FlexibleISO8601.date(from: "2026-08-10T00:00:00Z"))
        let now = start.addingTimeInterval(15 * 24 * 3_600)
        XCTAssertNotNil(metrics.sessionLimit?.pace(now: now))
        XCTAssertNotNil(metrics.weeklyLimit?.pace(now: now))
    }

    func testMapSummaryIgnoresNonPositiveBillingCycleDuration() throws {
        let json = """
        {
          "billingCycleStart": "2026-09-10T00:00:00Z",
          "billingCycleEnd": "2026-09-10T00:00:00Z",
          "individualUsage": {
            "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.resetTime, FlexibleISO8601.date(from: "2026-09-10T00:00:00Z"))
        XCTAssertNil(metrics.weeklyLimit?.windowSeconds)
        XCTAssertNil(metrics.sessionLimit?.windowSeconds)
        XCTAssertNil(metrics.weeklyLimit?.pace())
    }

    func testMapSummaryIgnoresTotalPercentUsedInFavorOfTheTwoPools() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 495, "limit": 500, "autoPercentUsed": 4, "apiPercentUsed": 64, "totalPercentUsed": 99 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.weeklyLimit?.used, 64)
        XCTAssertNotEqual(metrics.weeklyLimit?.used, 99)
        XCTAssertNotEqual(metrics.weeklyLimit?.used, 495)
    }

    func testMapSummaryMovesOnDemandToTheThirdWindowWhenPercentPoolsArePresent() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64, "used": 10, "limit": 500 },
            "onDemand": { "used": 12, "limit": 40, "enabled": true }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.used, 64)
        XCTAssertEqual(metrics.codeReviewLimit?.used, 12)
        XCTAssertEqual(metrics.codeReviewLimit?.total, 40)
        XCTAssertEqual(metrics.codeReviewLimit?.isEstimated, false)
    }

    func testMapSummaryZeroPercentIsARealEmptyPoolNotAMissingField() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "autoPercentUsed": 0, "apiPercentUsed": 0 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))

        XCTAssertEqual(metrics.sessionLimit?.used, 0)
        XCTAssertEqual(metrics.weeklyLimit?.used, 0)
        XCTAssertEqual(metrics.sessionLimit?.total, 100)
        XCTAssertEqual(metrics.weeklyLimit?.total, 100)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testMapSummaryWithoutSandStatusLeavesAdditionalLimitsEmpty() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 }
          }
        }
        """
        let metrics = CursorLocalService.mapSummary(try decodeSummary(json))
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    // MARK: - Grok Bot (GetSandUsageStatus)

    private func decodeSand(_ json: String) throws -> CursorSandUsageStatusResponse {
        try JSONDecoder().decode(CursorSandUsageStatusResponse.self, from: Data(json.utf8))
    }

    private let sandLiveKeysJSON = """
    {
      "currentPeriodStart": "2026-08-10T00:00:00.000Z",
      "nextResetTimestampUtc": "2026-08-17T00:00:00.000Z",
      "usagePercent": 18.5,
      "hasAvailableUsage": true,
      "hasNonZeroIncludedLimit": true
    }
    """

    func testSandUsageStatusDecodesLiveKeySet() throws {
        let status = try decodeSand(sandLiveKeysJSON)

        XCTAssertEqual(status.currentPeriodStart, "2026-08-10T00:00:00.000Z")
        XCTAssertEqual(status.nextResetTimestampUtc, "2026-08-17T00:00:00.000Z")
        XCTAssertEqual(status.usagePercent, 18.5)
        XCTAssertEqual(status.hasAvailableUsage, true)
        XCTAssertEqual(status.hasNonZeroIncludedLimit, true)
    }

    func testMapSummaryAttachesGrokBotWeeklyPercentPoolFromSandStatus() throws {
        let summary = """
        {
          "billingCycleStart": "2026-08-01T00:00:00Z",
          "billingCycleEnd": "2026-09-01T00:00:00Z",
          "individualUsage": {
            "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 },
            "onDemand": { "used": 2, "limit": 10, "enabled": true }
          }
        }
        """
        let sand = """
        {
          "currentPeriodStart": "2026-08-10T00:00:00Z",
          "nextResetTimestampUtc": "2026-08-17T00:00:00Z",
          "usagePercent": 18.5,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )

        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.used, 64)
        XCTAssertEqual(metrics.codeReviewLimit?.used, 2)
        XCTAssertEqual(metrics.additionalLimits.count, 1)
        let grokBot = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(grokBot.used, 18.5)
        XCTAssertEqual(grokBot.total, ServiceType.cursorIncludedPoolTotal)
        XCTAssertEqual(grokBot.periodKind, .weekly)
        XCTAssertEqual(grokBot.isEstimated, false)
        XCTAssertEqual(grokBot.resetTime, FlexibleISO8601.date(from: "2026-08-17T00:00:00Z"))
        XCTAssertEqual(grokBot.windowSeconds, 7 * 24 * 3_600)
        XCTAssertEqual(ServiceType.cursor.additionalQuotaTitleKey(for: grokBot), .grokBot)
    }

    func testMapSandOmitsWindowWhenPeriodStartMissing() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let sand = """
        {
          "nextResetTimestampUtc": "2026-08-17T00:00:00Z",
          "usagePercent": 12,
          "hasNonZeroIncludedLimit": true
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )
        let grokBot = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(grokBot.resetTime, FlexibleISO8601.date(from: "2026-08-17T00:00:00Z"))
        XCTAssertNil(grokBot.windowSeconds, "Start missing must not invent a 7-day window")
    }

    func testMapSandOmitsWindowWhenDurationIsNotPositive() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let equal = """
        {
          "currentPeriodStart": "2026-08-17T00:00:00Z",
          "nextResetTimestampUtc": "2026-08-17T00:00:00Z",
          "usagePercent": 12,
          "hasNonZeroIncludedLimit": true
        }
        """
        let inverted = """
        {
          "currentPeriodStart": "2026-08-17T00:00:00Z",
          "nextResetTimestampUtc": "2026-08-10T00:00:00Z",
          "usagePercent": 12,
          "hasNonZeroIncludedLimit": true
        }
        """

        for sand in [equal, inverted] {
            let metrics = CursorLocalService.mapSummary(
                try decodeSummary(summary),
                sandStatus: try decodeSand(sand)
            )
            let grokBot = try XCTUnwrap(metrics.additionalLimits.first)
            XCTAssertNil(grokBot.windowSeconds)
        }
    }

    func testMapSandOmitsBarWhenUsagePercentMissing() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let sand = """
        {
          "currentPeriodStart": "2026-08-10T00:00:00Z",
          "nextResetTimestampUtc": "2026-08-17T00:00:00Z",
          "hasNonZeroIncludedLimit": true
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.used, 64)
    }

    func testMapSandOmitsBarWhenUsesPooledEnterpriseAllowance() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let sand = """
        {
          "usagePercent": 40,
          "hasNonZeroIncludedLimit": true,
          "usesPooledEnterpriseAllowance": true
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testMapSandOmitsPhantomZeroWhenIncludedLimitIsZero() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let sand = """
        {
          "usagePercent": 0,
          "hasNonZeroIncludedLimit": false
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testMapSandKeepsZeroPercentWhenIncludedLimitIsNonZero() throws {
        let summary = #"{ "individualUsage": { "plan": { "autoPercentUsed": 4, "apiPercentUsed": 64 } } }"#
        let sand = """
        {
          "usagePercent": 0,
          "hasNonZeroIncludedLimit": true
        }
        """
        let metrics = CursorLocalService.mapSummary(
            try decodeSummary(summary),
            sandStatus: try decodeSand(sand)
        )
        let grokBot = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(grokBot.used, 0)
        XCTAssertEqual(grokBot.total, 100)
        XCTAssertEqual(grokBot.periodKind, .weekly)
    }

    func testAiserverHeadersCarryBearerAndConnectContract() {
        let headers = CursorLocalService.aiserverHeaders(token: "dummy-token")

        XCTAssertEqual(headers["Authorization"], "Bearer dummy-token")
        XCTAssertEqual(headers["Connect-Protocol-Version"], "1")
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["x-cursor-client-type"], "ide")
        XCTAssertFalse((headers["Authorization"] ?? "").contains("cursorAuth"))
    }

    // MARK: - Poll observations

    /// The single most important assertion about Cursor in this codebase.
    /// `/api/usage-summary` carries no currency field anywhere — `plan.used`,
    /// `plan.limit` and the on-demand figures are all integer counts against a
    /// plan allowance — so the observation is `.requests`. Flipping this to
    /// `.usd` would publish a request count as dollars in the spend chart, the
    /// dashboard total, and the share card.
    func testSummaryObservesPlanUsageAsRequestsNotDollars() throws {
        let json = """
        {
          "billingCycleStart": "2026-07-01T00:00:00Z",
          "billingCycleEnd": "2026-08-01T00:00:00Z",
          "individualUsage": {
            "plan": { "used": 137, "limit": 750 },
            "onDemand": { "used": 4, "limit": 20, "enabled": true }
          }
        }
        """
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)

        let observation = try XCTUnwrap(CursorLocalService.observation(try decodeSummary(json), at: observedAt))

        XCTAssertEqual(observation.provider, .cursor)
        XCTAssertEqual(observation.unit, .requests)
        XCTAssertEqual(observation.runningTotal, 137)
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.dayBoundary, .local, "deltas are dated when MeterBar saw them")
    }

    /// On-demand spend is billed separately and counted separately, so adding it
    /// to the plan count would produce a number in neither unit. It is left out
    /// rather than folded in.
    func testOnDemandUsageIsNotAddedToThePlanCount() throws {
        let json = """
        {
          "individualUsage": {
            "plan": { "used": 100, "limit": 500 },
            "onDemand": { "used": 25, "limit": 50, "enabled": true }
          }
        }
        """

        let observation = try XCTUnwrap(CursorLocalService.observation(try decodeSummary(json), at: Date()))

        XCTAssertEqual(observation.runningTotal, 100)
    }

    /// Cursor publishes no per-day figure at all, so there is nothing
    /// authoritative to prefer over the poll-to-poll delta.
    func testSummaryPublishesNoAuthoritativeDailyTotal() throws {
        let json = #"{ "individualUsage": { "plan": { "used": 3, "limit": 500 } } }"#

        let observation = try XCTUnwrap(CursorLocalService.observation(try decodeSummary(json), at: Date()))

        XCTAssertNil(observation.authoritativeDailyTotal)
    }

    /// A payload with no plan counter is not a reading of zero, and must not be
    /// reported as one: the ledger reads a drop as a billing-cycle reset and
    /// re-baselines, so the next complete poll would charge the whole
    /// cycle-to-date count to a single day.
    func testMissingPlanCounterYieldsNoObservationRatherThanZero() throws {
        XCTAssertNil(CursorLocalService.observation(try decodeSummary("{}"), at: Date()))
        XCTAssertNil(
            CursorLocalService.observation(try decodeSummary(#"{ "individualUsage": {} }"#), at: Date())
        )
    }

    func testEmptySummaryStillYieldsNoObservationWithTeamFallback() throws {
        XCTAssertNil(CursorLocalService.observation(try decodeSummary("{}"), at: Date()))
    }

    func testSummaryObservesTeamPlanRunningTotal() throws {
        let json = """
        {
          "teamUsage": {
            "plan": { "used": 612, "limit": 1500 }
          }
        }
        """
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)

        let observation = try XCTUnwrap(CursorLocalService.observation(try decodeSummary(json), at: observedAt))

        XCTAssertEqual(observation.runningTotal, 612)
        XCTAssertEqual(observation.unit, .requests)
        XCTAssertEqual(observation.observedAt, observedAt)
    }

    /// A published zero is a real reading, though — the start of a billing cycle
    /// — and still establishes the baseline the next poll differences against.
    func testExplicitZeroPlanCounterIsStillObserved() throws {
        let json = #"{ "individualUsage": { "plan": { "used": 0, "limit": 500 } } }"#

        let observation = try XCTUnwrap(CursorLocalService.observation(try decodeSummary(json), at: Date()))

        XCTAssertEqual(observation.runningTotal, 0)
        XCTAssertEqual(observation.unit, .requests)
    }

    func testTwoPoolPercentPayloadYieldsNoRequestObservation() throws {
        let json = """
        {
          "individualUsage": {
            "plan": {
              "used": 495,
              "limit": 500,
              "autoPercentUsed": 4,
              "apiPercentUsed": 64
            }
          }
        }
        """

        XCTAssertNil(CursorLocalService.observation(try decodeSummary(json), at: Date()))
    }

    // MARK: - JWT userId extraction

    func testExtractUserIdSplitsAuth0PrefixedSub() {
        let token = makeJWT(sub: "auth0|user-abc123")
        XCTAssertEqual(CursorLocalService.extractUserIdFromJWT(token), "user-abc123")
    }

    func testExtractUserIdReturnsPlainSub() {
        let token = makeJWT(sub: "user-xyz")
        XCTAssertEqual(CursorLocalService.extractUserIdFromJWT(token), "user-xyz")
    }

    func testExtractUserIdReturnsNilForMalformedToken() {
        XCTAssertNil(CursorLocalService.extractUserIdFromJWT("not-a-jwt"))
    }

    // MARK: - Off-main fetch regression

    /// Regression for the 1.8.38 SIGSEGV entering `NSURLSession.data` during
    /// Cursor refresh: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the
    /// usage-summary / sand legs ran as main-actor jobs through a *stored*
    /// fetch closure's reabstraction thunk (OpenRouter #480, Codex #328).
    /// Network + decode now run detached; probing that path from off the main
    /// actor through a stored `@Sendable` closure must still succeed.
    func testFetchRemotelyProbedThroughStoredClosureFromDetachedTask() async throws {
        let summaryJSON = """
        {
          "billingCycleStart": "2026-07-01T00:00:00Z",
          "billingCycleEnd": "2026-08-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": { "used": 10, "limit": 100 },
            "onDemand": { "used": 0, "limit": 20, "enabled": true }
          }
        }
        """
        let sandJSON = """
        {
          "currentPeriodStart": "2026-07-01T00:00:00Z",
          "nextResetTimestampUtc": "2026-07-08T00:00:00Z",
          "usagePercent": 12,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true
        }
        """

        let fetched = try await Task.detached(priority: .userInitiated) {
            let fetchData: @Sendable (URLRequest) async throws -> Data = { request in
                let path = request.url?.path ?? ""
                if path.contains("usage-summary") {
                    return Data(summaryJSON.utf8)
                }
                if path.contains("GetSandUsageStatus") {
                    return Data(sandJSON.utf8)
                }
                throw ServiceError.invalidURL
            }
            return try await CursorLocalService.fetchRemotely(
                userId: "user-test",
                token: "tok-test",
                fetchData: fetchData
            )
        }.value

        XCTAssertEqual(fetched.metrics.service, .cursor)
        XCTAssertEqual(fetched.membershipType, "pro")
        XCTAssertEqual(fetched.metrics.weeklyLimit?.used, 10)
        XCTAssertEqual(fetched.metrics.weeklyLimit?.total, 100)
        XCTAssertEqual(fetched.observation?.runningTotal, 10)
        XCTAssertEqual(fetched.metrics.additionalLimits.first?.used, 12)
    }

    /// The stronger pin for the same 1.8.38 crash: even when the poll is
    /// awaited from the main actor, the stored fetch closure itself must run
    /// detached — it executing as a main-actor job is the exact hazard.
    @MainActor
    func testFetchRemotelyRunsStoredFetchClosureOffMainThread() async throws {
        nonisolated final class ThreadRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var sawMainThread = false
            private var callCount = 0
            func record() {
                lock.lock()
                defer { lock.unlock() }
                if Thread.isMainThread { sawMainThread = true }
                callCount += 1
            }
            var wasCalledOnMainThread: Bool {
                lock.lock()
                defer { lock.unlock() }
                return sawMainThread
            }
            var wasCalled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return callCount > 0
            }
        }

        let summaryJSON = """
        {
          "billingCycleStart": "2026-07-01T00:00:00Z",
          "billingCycleEnd": "2026-08-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": { "used": 10, "limit": 100 },
            "onDemand": { "used": 0, "limit": 20, "enabled": true }
          }
        }
        """
        let recorder = ThreadRecorder()
        let fetchData: @Sendable (URLRequest) async throws -> Data = { request in
            recorder.record()
            let path = request.url?.path ?? ""
            if path.contains("usage-summary") {
                return Data(summaryJSON.utf8)
            }
            throw ServiceError.invalidURL
        }

        let fetched = try await CursorLocalService.fetchRemotely(
            userId: "user-test",
            token: "tok-test",
            fetchData: fetchData
        )

        XCTAssertEqual(fetched.metrics.service, .cursor)
        XCTAssertTrue(recorder.wasCalled)
        XCTAssertFalse(
            recorder.wasCalledOnMainThread,
            "the stored fetch closure must never run as a main-actor job"
        )
    }
}
