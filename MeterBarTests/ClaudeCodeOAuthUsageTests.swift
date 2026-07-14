import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Covers the OAuth-primary path for Claude Code usage: the pure response→metrics
/// mapping, the source-selection policy, and the enabled-by-default flag. The
/// network/Keychain fetch itself is exercised by CI/integration, not here.
final class ClaudeCodeOAuthUsageTests: XCTestCase {
    // MARK: - Response → UsageMetrics mapping

    func testMetricsMapsAllWindowsAndExtraUsage() throws {
        let response = try decodeUsage(#"""
        {
          "five_hour": {"utilization": 61.5, "resets_at": "2026-07-02T14:00:00Z"},
          "seven_day": {"utilization": 30.0, "resets_at": "2026-07-08T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-07-08T00:00:00Z"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 50.0, "currency": "USD"}
        }
        """#)

        let metrics = ClaudeCodeLocalService.metrics(from: response)

        XCTAssertEqual(metrics.service, .claudeCode)
        let session = try XCTUnwrap(metrics.sessionLimit)
        let weekly = try XCTUnwrap(metrics.weeklyLimit)
        let sonnet = try XCTUnwrap(metrics.codeReviewLimit)
        XCTAssertEqual(session.percentage, 61.5, accuracy: 0.01)
        XCTAssertEqual(session.windowSeconds, 5 * 60 * 60)
        XCTAssertEqual(weekly.percentage, 30.0, accuracy: 0.01)
        XCTAssertEqual(weekly.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(sonnet.percentage, 12.0, accuracy: 0.01)
        XCTAssertEqual(sonnet.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertNotNil(session.resetTime)
        XCTAssertEqual(metrics.extraUsage?.state, .on)
    }

    func testMetricsOmitsModelWindowWhenAbsent() throws {
        let response = try decodeUsage(#"""
        {
          "five_hour": {"utilization": 5.0, "resets_at": "2026-07-02T14:00:00Z"},
          "seven_day": {"utilization": 10.0, "resets_at": "2026-07-08T00:00:00Z"}
        }
        """#)

        let metrics = ClaudeCodeLocalService.metrics(from: response)

        XCTAssertNotNil(metrics.sessionLimit)
        XCTAssertNotNil(metrics.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
    }

    // MARK: - Source-selection policy

    func testPrefersOAuthOnlyForDefaultAccountWhenEnabled() {
        XCTAssertTrue(ClaudeCodeLocalService.prefersOAuth(account: .defaultAccount, oauthEnabled: true))
        XCTAssertFalse(ClaudeCodeLocalService.prefersOAuth(account: .defaultAccount, oauthEnabled: false))

        let custom = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        XCTAssertFalse(ClaudeCodeLocalService.prefersOAuth(account: custom, oauthEnabled: true))
        XCTAssertFalse(ClaudeCodeLocalService.prefersOAuth(account: custom, oauthEnabled: false))
    }

    // MARK: - Enabled-by-default flag

    func testOAuthUsageEnabledDefaultsTrueWhenUnset() throws {
        let defaults = try makeEmptyDefaults()
        XCTAssertTrue(ClaudeCodeLocalService.isOAuthUsageEnabled(defaults: defaults))
    }

    func testOAuthUsageRespectsExplicitOptOut() throws {
        let defaults = try makeEmptyDefaults()
        defaults.set(false, forKey: StorageKeys.claudeCodeOAuthFallback)
        XCTAssertFalse(ClaudeCodeLocalService.isOAuthUsageEnabled(defaults: defaults))

        defaults.set(true, forKey: StorageKeys.claudeCodeOAuthFallback)
        XCTAssertTrue(ClaudeCodeLocalService.isOAuthUsageEnabled(defaults: defaults))
    }

    // MARK: - Helpers

    private func decodeUsage(_ json: String) throws -> ClaudeCodeUsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try decoder.decode(ClaudeCodeUsageResponse.self, from: data)
    }

    private func makeEmptyDefaults() throws -> UserDefaults {
        let suite = "ClaudeCodeOAuthUsageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
