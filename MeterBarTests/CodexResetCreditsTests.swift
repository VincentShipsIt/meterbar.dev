import XCTest
import MeterBarShared
@testable import MeterBar

/// Tests for parsing and carrying Codex "banked rate-limit resets" — the
/// `rate_limit_reset_credits.available_count` field on the wham/usage payload,
/// surfaced in the UI as "N reset available".
final class CodexResetCreditsTests: XCTestCase {
    private func decode(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: Data(json.utf8))
    }

    func testDecodesAvailableResetCount() throws {
        let response = try decode(#"""
        { "plan_type": "pro", "rate_limit": null, "rate_limit_reset_credits": { "available_count": 1 } }
        """#)
        XCTAssertEqual(response.resetCreditsAvailable, 1)
    }

    func testAbsentResetCreditsIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit": null }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    func testNullResetCreditsIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit_reset_credits": null }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    func testNullAvailableCountIsNil() throws {
        let response = try decode(#"{ "plan_type": "pro", "rate_limit_reset_credits": { "available_count": null } }"#)
        XCTAssertNil(response.resetCreditsAvailable)
    }

    /// Mirrors the real wham/usage payload, including fields the app does not model
    /// (`additional_rate_limits`, `spend_control`, `promo`) to prove forward-compatible
    /// decoding doesn't break when ChatGPT adds keys.
    func testDecodesAlongsideUnknownFields() throws {
        let response = try decode(#"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": { "used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1781959611 },
            "secondary_window": { "used_percent": 35, "limit_window_seconds": 604800, "reset_after_seconds": 426296, "reset_at": 1782367907 }
          },
          "additional_rate_limits": [ { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox", "rate_limit": null } ],
          "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0" },
          "spend_control": { "reached": false, "individual_limit": null },
          "promo": null,
          "rate_limit_reset_credits": { "available_count": 1 }
        }
        """#)
        XCTAssertEqual(response.resetCreditsAvailable, 1)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.usedPercent, 35)
    }

    func testUsageMetricsCarriesResetCredits() {
        let metrics = UsageMetrics(service: .codexCli, resetCreditsAvailable: 2)
        XCTAssertEqual(metrics.resetCreditsAvailable, 2)

        // withExtraUsage must preserve the reset-credit count alongside the new status.
        let updated = metrics.withExtraUsage(.unknown)
        XCTAssertEqual(updated.resetCreditsAvailable, 2)
        XCTAssertEqual(updated.extraUsage, .unknown)
    }

    func testUsageMetricsResetCreditsDefaultsNil() {
        XCTAssertNil(UsageMetrics(service: .claudeCode).resetCreditsAvailable)
    }
}
