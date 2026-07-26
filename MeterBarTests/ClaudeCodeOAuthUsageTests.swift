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
        XCTAssertEqual(metrics.modelLimitLabel, "Sonnet")
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
        XCTAssertNil(metrics.modelLimitLabel)
    }

    func testMetricsMapsFableWindowWithoutRelabelingItAsSonnet() throws {
        let response = try decodeUsage(#"""
        {
          "five_hour": {"utilization": 16.0, "resets_at": "2026-07-02T14:00:00Z"},
          "seven_day": {"utilization": 71.0, "resets_at": "2026-07-08T00:00:00Z"},
          "seven_day_fable": {"utilization": 100.0, "resets_at": "2026-07-08T00:00:00Z"}
        }
        """#)

        let metrics = ClaudeCodeLocalService.metrics(from: response)

        XCTAssertEqual(metrics.codeReviewLimit?.percentage, 100.0)
        XCTAssertEqual(metrics.modelLimitLabel, "Fable")
        guard case .good = metrics.overallStatus else {
            return XCTFail("A Fable-only exhaustion must not mark Claude unavailable.")
        }
    }

    // MARK: - Source-selection policy

    /// OAuth used to be restricted to the unscoped default account, because the
    /// single global Keychain item could belong to a different Claude identity.
    /// Credentials are now resolved per profile, so the switch is just the user's
    /// opt-out — and the anti-contamination guarantee moved into the resolver's
    /// candidate list, which is what these assertions pin.
    func testScopedProfilesResolveTheirOwnCredentialInsteadOfTheGlobalOne() {
        let unscoped = ClaudeCredentialResolver.candidates(
            for: .defaultAccount,
            environment: [:],
            realHomeDirectory: "/Users/tester"
        )
        XCTAssertTrue(
            unscoped.contains(.keychain(service: ClaudeCredentialResolver.bareKeychainService)),
            "The canonical profile is the one the unscoped item belongs to"
        )

        // A default-ID account that names its own config directory is a scoped
        // profile, not the canonical one — the case that previously forced the CLI.
        let savedDefault = ClaudeCodeAccount(
            id: ClaudeCodeAccount.defaultID,
            name: "genfeedai",
            configDirectory: "/Users/tester/.claude-genfeedai"
        )
        let custom = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/Users/tester/.claude-work")

        for account in [savedDefault, custom] {
            let candidates = ClaudeCredentialResolver.candidates(
                for: account,
                environment: [:],
                realHomeDirectory: "/Users/tester"
            )
            XCTAssertFalse(
                candidates.contains(.keychain(service: ClaudeCredentialResolver.bareKeychainService)),
                "\(account.name) must never read the unscoped identity's credential"
            )
            XCTAssertEqual(
                candidates.first,
                .keychain(service: ClaudeCredentialResolver.keychainService(
                    forConfigDirectory: ClaudeCredentialResolver.configDirectory(
                        for: account,
                        environment: [:],
                        realHomeDirectory: "/Users/tester"
                    )
                ))
            )
        }
    }

    func testOnlyDefaultAccountPublishesProviderWideConnectionState() {
        let custom = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")

        XCTAssertTrue(ClaudeCodeLocalService.publishesSharedConnectionState(for: .defaultAccount))
        XCTAssertFalse(ClaudeCodeLocalService.publishesSharedConnectionState(for: custom))
    }

    // MARK: - Pure OAuth fetch (side-effect-free)

    func testOAuthFetchThrowsInvalidURLForEmptyEndpoint() async {
        // The pure fetch validates the endpoint before touching the network, so
        // this exercises it without a request. It also proves the fetch is a
        // plain `static` callable from a nonisolated (background) context — the
        // property the session-wake path depends on.
        do {
            _ = try await ClaudeCodeLocalService.fetchOAuthMetrics(token: "token", endpoint: "")
            XCTFail("An empty endpoint must throw before any network call")
        } catch ServiceError.invalidURL {
            // expected
        } catch {
            XCTFail("Expected ServiceError.invalidURL, got \(error)")
        }
    }

    // MARK: - Shared usage request builder

    func testUsageRequestCarriesTheOAuthHeaderSet() throws {
        let request = try XCTUnwrap(ClaudeCodeLocalService.usageRequest(
            token: "secret-token",
            endpoint: ClaudeCodeLocalService.defaultUsageEndpoint,
            timeout: 30
        ))

        XCTAssertEqual(request.url?.absoluteString, ClaudeCodeLocalService.defaultUsageEndpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testUsageRequestKeepsCallerTimeoutsDistinct() throws {
        // The two call sites deliberately differ: the metrics fetch is the
        // user-visible reading and gets 30s, while the extra-usage probe is
        // best-effort and must not stall a refresh, so it gets 15s. Collapsing
        // them onto one value would be a behaviour change, not a dedupe.
        let metrics = try XCTUnwrap(ClaudeCodeLocalService.usageRequest(
            token: "t",
            timeout: ClaudeCodeLocalService.usageRequestTimeout
        ))
        let extraUsage = try XCTUnwrap(ClaudeCodeLocalService.usageRequest(
            token: "t",
            timeout: ClaudeCodeLocalService.extraUsageRequestTimeout
        ))

        XCTAssertEqual(metrics.timeoutInterval, 30)
        XCTAssertEqual(extraUsage.timeoutInterval, 15)
    }

    func testUsageRequestRejectsAnUnusableEndpoint() {
        XCTAssertNil(ClaudeCodeLocalService.usageRequest(token: "t", endpoint: "", timeout: 30))
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
