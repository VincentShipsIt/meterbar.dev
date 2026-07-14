import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Extends PR #175's OAuth-primary usage source to the session-wake quota gate.
///
/// `LiveWakeQuotaProvider` must prefer the side-effect-free OAuth fetch for the
/// default account (whose token lives in the Keychain) and fall back to the CLI
/// for custom accounts, a missing token, or an OAuth opt-out — matching the
/// selection policy the usage card already uses, and without any UI side
/// effects or network. The injected closures exercise that selection in
/// isolation.
final class WakeQuotaProviderSelectionTests: XCTestCase {
    private func metrics(session used: Double) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil)
        )
    }

    /// Thread-safe recorder for which source path a fetch took. The provider's
    /// closures are `@Sendable`, so mutation must be isolated.
    private actor CallRecorder {
        private(set) var oauthCalls = 0
        private(set) var cliAccounts: [ClaudeCodeAccount] = []
        func recordOAuth() { oauthCalls += 1 }
        func recordCLI(_ account: ClaudeCodeAccount) { cliAccounts.append(account) }
    }

    func testDefaultAccountPrefersOAuthWhenTokenPresent() async throws {
        let recorder = CallRecorder()
        let provider = LiveWakeQuotaProvider(
            oauthMetrics: { await recorder.recordOAuth(); return self.metrics(session: 42) },
            cliMetrics: { account in await recorder.recordCLI(account); return self.metrics(session: 99) },
            oauthEnabled: { true }
        )

        let result = try await provider.fetchMetrics(account: .defaultAccount)

        XCTAssertEqual(try XCTUnwrap(result.sessionLimit).percentage, 42, accuracy: 0.01)
        let oauthCalls = await recorder.oauthCalls
        let cliAccounts = await recorder.cliAccounts
        XCTAssertEqual(oauthCalls, 1)
        XCTAssertTrue(cliAccounts.isEmpty, "OAuth success must not also hit the CLI")
    }

    func testDefaultAccountFallsBackToCLIWhenNoToken() async throws {
        let recorder = CallRecorder()
        let provider = LiveWakeQuotaProvider(
            oauthMetrics: { await recorder.recordOAuth(); return nil }, // no usable Keychain token
            cliMetrics: { account in await recorder.recordCLI(account); return self.metrics(session: 7) },
            oauthEnabled: { true }
        )

        let result = try await provider.fetchMetrics(account: .defaultAccount)

        XCTAssertEqual(try XCTUnwrap(result.sessionLimit).percentage, 7, accuracy: 0.01)
        let oauthCalls = await recorder.oauthCalls
        let cliAccounts = await recorder.cliAccounts
        XCTAssertEqual(oauthCalls, 1)
        XCTAssertEqual(cliAccounts, [.defaultAccount])
    }

    func testDefaultAccountUsesCLIWhenOAuthDisabled() async throws {
        let recorder = CallRecorder()
        let provider = LiveWakeQuotaProvider(
            oauthMetrics: { await recorder.recordOAuth(); return self.metrics(session: 1) },
            cliMetrics: { account in await recorder.recordCLI(account); return self.metrics(session: 55) },
            oauthEnabled: { false }
        )

        let result = try await provider.fetchMetrics(account: .defaultAccount)

        XCTAssertEqual(try XCTUnwrap(result.sessionLimit).percentage, 55, accuracy: 0.01)
        let oauthCalls = await recorder.oauthCalls
        let cliAccounts = await recorder.cliAccounts
        XCTAssertEqual(oauthCalls, 0, "An OAuth opt-out must skip the OAuth path entirely")
        XCTAssertEqual(cliAccounts, [.defaultAccount])
    }

    func testCustomAccountAlwaysUsesCLI() async throws {
        let recorder = CallRecorder()
        let custom = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let provider = LiveWakeQuotaProvider(
            oauthMetrics: { await recorder.recordOAuth(); return self.metrics(session: 1) },
            cliMetrics: { account in await recorder.recordCLI(account); return self.metrics(session: 33) },
            oauthEnabled: { true }
        )

        let result = try await provider.fetchMetrics(account: custom)

        XCTAssertEqual(try XCTUnwrap(result.sessionLimit).percentage, 33, accuracy: 0.01)
        let oauthCalls = await recorder.oauthCalls
        let cliAccounts = await recorder.cliAccounts
        XCTAssertEqual(oauthCalls, 0, "Custom accounts have no Keychain token; never hit OAuth")
        XCTAssertEqual(cliAccounts, [custom])
    }

    func testOAuthFailurePropagatesAndDoesNotFallBackToCLI() async {
        struct Boom: Error {}
        let recorder = CallRecorder()
        let provider = LiveWakeQuotaProvider(
            oauthMetrics: { await recorder.recordOAuth(); throw Boom() },
            cliMetrics: { account in await recorder.recordCLI(account); return self.metrics(session: 5) },
            oauthEnabled: { true }
        )

        do {
            _ = try await provider.fetchMetrics(account: .defaultAccount)
            XCTFail("A token-present OAuth failure must propagate, not silently fall back")
        } catch {
            // expected — fail closed
        }

        let cliAccounts = await recorder.cliAccounts
        XCTAssertTrue(cliAccounts.isEmpty, "OAuth error must fail closed, not retry the headless-broken CLI")
    }
}
