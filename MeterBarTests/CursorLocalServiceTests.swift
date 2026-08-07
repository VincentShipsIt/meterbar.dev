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
        XCTAssertEqual(metrics.sessionLimit?.used, 4)
        XCTAssertEqual(metrics.sessionLimit?.total, 20)
        XCTAssertEqual(metrics.sessionLimit?.isEstimated, false)
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

        let observation = CursorLocalService.observation(try decodeSummary(json), at: observedAt)

        XCTAssertEqual(observation.provider, .cursor)
        XCTAssertEqual(observation.unit, .requests)
        XCTAssertEqual(observation.runningTotal, 137)
        XCTAssertEqual(observation.observedAt, observedAt)
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

        let observation = CursorLocalService.observation(try decodeSummary(json), at: Date())

        XCTAssertEqual(observation.runningTotal, 100)
    }

    /// Cursor publishes no per-day figure at all, so there is nothing
    /// authoritative to prefer over the poll-to-poll delta.
    func testSummaryPublishesNoAuthoritativeDailyTotal() throws {
        let json = #"{ "individualUsage": { "plan": { "used": 3, "limit": 500 } } }"#

        let observation = CursorLocalService.observation(try decodeSummary(json), at: Date())

        XCTAssertNil(observation.authoritativeDailyTotal)
    }

    /// A payload with no individual usage at all still yields a well-formed
    /// baseline. Zero here is the counter's value, not a claim about a day —
    /// the ledger writes no row for an unchanged counter.
    func testMissingIndividualUsageObservesZeroRatherThanFailing() throws {
        let observation = CursorLocalService.observation(try decodeSummary("{}"), at: Date())

        XCTAssertEqual(observation.runningTotal, 0)
        XCTAssertEqual(observation.unit, .requests)
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
}
