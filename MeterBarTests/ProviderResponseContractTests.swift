import XCTest
@testable import MeterBar
import MeterBarShared

/// Contract tests for the provider response models.
///
/// Every endpoint MeterBar consumes is undocumented/reverse-engineered
/// (see docs/audits/00-repo-map.md, risk R1). These fixtures lock the decode
/// assumptions so an accidental model change fails loudly here instead of
/// silently blanking a provider card at runtime. When a provider changes its
/// payload for real, update the fixture together with the model.
final class ProviderResponseContractTests: XCTestCase {

    // MARK: - Codex (https://chatgpt.com/backend-api/wham/usage)

    func testCodexFullResponseDecodesWindowsAndPlan() throws {
        let json = #"""
        {
          "plan_type": "team",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 42.5,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1782000000
            },
            "secondary_window": {
              "used_percent": 12.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86400,
              "reset_at": 1782500000
            }
          },
          "code_review_rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 5.0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 100,
              "reset_at": 1782600000
            }
          }
        }
        """#
        let response = try decodeCodex(json)

        XCTAssertEqual(response.planType, "team")
        let rateLimit = try XCTUnwrap(response.rateLimit)
        XCTAssertEqual(rateLimit.primaryWindow.usedPercent, 42.5)
        XCTAssertEqual(rateLimit.primaryWindow.limitWindowSeconds, 18000)
        XCTAssertEqual(rateLimit.primaryWindow.resetAt, 1_782_000_000)
        let secondary = try XCTUnwrap(rateLimit.secondaryWindow)
        XCTAssertEqual(secondary.usedPercent, 12.0)
        XCTAssertEqual(secondary.limitWindowSeconds, 604_800)
        let codeReview = try XCTUnwrap(response.codeReviewRateLimit)
        XCTAssertEqual(codeReview.primaryWindow.usedPercent, 5.0)
    }

    func testCodexFreeAccountNullRateLimitDecodes() throws {
        let response = try decodeCodex(#"{"plan_type":"free","rate_limit":null}"#)
        XCTAssertEqual(response.planType, "free")
        XCTAssertNil(response.rateLimit)
    }

    func testCodexStringNumericFieldsAreTolerated() throws {
        // The API has been observed returning numbers as strings for
        // credits.balance and spend_control.individual_limit.
        let json = #"""
        {
          "plan_type": "plus",
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "overage_limit_reached": false,
            "balance": "12.50"
          },
          "spend_control": {"reached": false, "individual_limit": "40"}
        }
        """#
        let response = try decodeCodex(json)
        XCTAssertEqual(response.credits?.balance, 12.5)
        XCTAssertEqual(response.spendControl?.individualLimit, 40)
    }

    // MARK: - Cursor (https://cursor.com/api/usage-summary)

    func testCursorUsageSummaryDecodes() throws {
        let json = #"""
        {
          "billingCycleStart": "2026-06-15T00:00:00.000Z",
          "billingCycleEnd": "2026-07-15T00:00:00.000Z",
          "membershipType": "pro",
          "limitType": "requests",
          "individualUsage": {
            "plan": {"used": 132, "limit": 500, "remaining": 368, "included": 500, "bonus": 0, "total": 500},
            "onDemand": {"used": 3, "limit": 20, "remaining": 17, "enabled": true}
          }
        }
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)

        XCTAssertEqual(response.membershipType, "pro")
        XCTAssertEqual(response.billingCycleEnd, "2026-07-15T00:00:00.000Z")
        let plan = try XCTUnwrap(response.individualUsage?.plan)
        XCTAssertEqual(plan.used, 132)
        XCTAssertEqual(plan.total, 500)
        let onDemand = try XCTUnwrap(response.individualUsage?.onDemand)
        XCTAssertEqual(onDemand.enabled, true)
        XCTAssertEqual(onDemand.used, 3)
    }

    func testCursorSparseResponseDecodes() throws {
        // Every field is optional; an empty object must not throw.
        let data = try XCTUnwrap("{}".data(using: .utf8))
        let response = try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
        XCTAssertNil(response.individualUsage)
        XCTAssertNil(response.billingCycleEnd)
    }

    // MARK: - Claude Code OAuth usage (https://api.anthropic.com/api/oauth/usage)

    func testClaudeCodeUsageResponseDecodesWindows() throws {
        let json = #"""
        {
          "five_hour": {"utilization": 61.5, "resets_at": "2026-07-02T14:00:00Z"},
          "seven_day": {"utilization": 30.0, "resets_at": "2026-07-08T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-07-08T00:00:00Z"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 50.0, "currency": "USD"},
          "spend": {
            "used": {"amount_minor": 750, "currency": "USD", "exponent": 2},
            "enabled": true
          }
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)

        XCTAssertEqual(response.fiveHour.utilization, 61.5)
        XCTAssertEqual(response.sevenDay.utilization, 30.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 12.0)
        XCTAssertNil(response.sevenDayFable)
        // Minor-unit money: 750 with exponent 2 is $7.50.
        XCTAssertEqual(response.spend?.used?.amount, 7.5)
        XCTAssertEqual(response.extraUsageStatus.state, .on)
    }

    func testClaudeCodeUsageResponseRequiresBothCoreWindows() throws {
        // five_hour and seven_day are non-optional in the model. If the API
        // drops one, decode must fail (caught and surfaced as parsingError)
        // rather than fabricating zeros.
        let json = #"{"five_hour": {"utilization": 1.0, "resets_at": "2026-07-02T14:00:00Z"}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try decoder.decode(ClaudeCodeUsageResponse.self, from: data))
    }

    // MARK: - Helpers

    private func decodeCodex(_ json: String) throws -> CodexCliUsageResponse {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(CodexCliUsageResponse.self, from: data)
    }
}
