import XCTest
import MeterBarShared

/// Fixture-driven unit tests for the pure `ProviderReadinessEvaluator` core.
///
/// These exercise the check logic without any filesystem/keychain/SQLite I/O:
/// every input is a fixture (missing auth file, expired token, unreadable DB,
/// healthy). The impure gathering lives in `ProviderReadinessInspector`; this
/// suite is what lets the leveling + redaction logic be trusted.
final class ProviderReadinessTests: XCTestCase {
    // Fixed clock so token-expiry checks are deterministic.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // A token value that must never appear in user-facing output.
    private let secret = "SECRET-TOKEN-DO-NOT-LEAK-abc123"

    func testOpenRouterRequiresKeyAndSurfacesSanitizedRefreshFailure() {
        let missing = ProviderReadinessEvaluator.openRouter(OpenRouterReadinessInput(hasAPIKey: false))
        XCTAssertEqual(missing.provider, .openRouter)
        XCTAssertEqual(missing.check("auth")?.level, .fail)
        XCTAssertTrue((missing.check("auth")?.recovery ?? "").contains("Settings"))

        let configured = ProviderReadinessEvaluator.openRouter(
            OpenRouterReadinessInput(hasAPIKey: true, refreshError: "API error (HTTP 401)")
        )
        XCTAssertEqual(configured.check("auth")?.level, .pass)
        XCTAssertEqual(configured.check("refresh")?.level, .fail)
        XCTAssertFalse(configured.isHealthy)
    }

    func testGrokRequiresCLIAndCachedLogin() {
        let missing = ProviderReadinessEvaluator.grok(
            GrokReadinessInput(isCLIInstalled: false, authFileExists: false, authFileReadable: false)
        )
        XCTAssertEqual(missing.provider, .grok)
        XCTAssertEqual(missing.check("installed")?.level, .fail)
        XCTAssertEqual(missing.check("auth")?.level, .fail)
        XCTAssertTrue((missing.check("auth")?.recovery ?? "").contains("grok login"))

        let ready = ProviderReadinessEvaluator.grok(
            GrokReadinessInput(isCLIInstalled: true, authFileExists: true, authFileReadable: true)
        )
        XCTAssertEqual(ready.overall, .pass)
        XCTAssertEqual(ready.check("data")?.level, .pass)
    }

    // MARK: - Claude Code

    func testClaudeHealthy() {
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: claudeCredentials(accessToken: secret, expiresAtUnix: 2_000_000),
            refreshError: nil,
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.provider, .claudeCode)
        XCTAssertEqual(report.overall, .pass)
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.check("installed")?.level, .pass)
        XCTAssertEqual(report.check("auth")?.level, .pass)
        XCTAssertEqual(report.check("data")?.level, .pass)
        XCTAssertEqual(report.check("refresh")?.level, .pass)
        assertNoSecretLeak(report)
    }

    func testClaudeNotInstalledFailsWithLoginRecovery() {
        let input = ClaudeReadinessInput(isCLIInstalled: false, credentialsJSON: nil, now: now)
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.overall, .fail)
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.check("installed")?.level, .fail)
        XCTAssertTrue((report.check("installed")?.recovery ?? "").contains("claude login"))
    }

    func testClaudeMissingCredentialsWithCLIInstalledWarnsAuth() {
        // Standard `claude login` flow: the CLI session's credentials are not
        // readable by the app, so "no keychain blob" is inconclusive — warn,
        // never a hard fail (the old fail here false-negatived every CLI-login
        // user whose usage hadn't been fetched yet).
        let input = ClaudeReadinessInput(isCLIInstalled: true, credentialsJSON: nil, now: now)
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .warn)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("claude login"))
        XCTAssertEqual(report.overall, .warn)
    }

    func testClaudeMissingCredentialsWithoutCLIFailsAuth() {
        let input = ClaudeReadinessInput(isCLIInstalled: false, credentialsJSON: nil, now: now)
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("claude login"))
        XCTAssertEqual(report.overall, .fail)
    }

    func testClaudeRecentUsageFetchPassesAuthWithoutCredentials() {
        // A recent successful usage fetch runs through the CLI session, so it
        // is direct proof of sign-in even with no readable keychain blob.
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: nil,
            hasRecentUsageFetch: true,
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .pass)
        XCTAssertEqual(report.check("data")?.level, .pass)
        XCTAssertEqual(report.overall, .pass)
        XCTAssertTrue(report.isHealthy)
    }

    func testClaudeRecentUsageFetchOverridesExpiredLegacyCredentials() {
        // The legacy keychain blob can sit expired while the CLI session works
        // fine; live fetch evidence wins over stale credential inspection.
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: claudeCredentials(accessToken: secret, expiresAtUnix: 500_000), // past
            hasRecentUsageFetch: true,
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .pass)
        assertNoSecretLeak(report)
    }

    func testClaudeExpiredTokenFailsAuth() {
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: claudeCredentials(accessToken: secret, expiresAtUnix: 500_000), // past
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.detail.lowercased() ?? "").contains("expired"))
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("claude login"))
        assertNoSecretLeak(report)
    }

    func testClaudeMissingAccessTokenFailsAuth() {
        let credentials = """
        {"claudeAiOauth":{"refreshToken":"refresh","expiresAt":2000000,\
        "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default"}}
        """
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: Data(credentials.utf8),
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.detail ?? "").contains("usable access token"))
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("claude login"))
        XCTAssertEqual(report.overall, .fail)
    }

    func testClaudeBlankAccessTokenFailsAuth() {
        let input = ClaudeReadinessInput(
            isCLIInstalled: true,
            credentialsJSON: claudeCredentials(accessToken: "   ", expiresAtUnix: 2_000_000),
            now: now
        )
        let report = ProviderReadinessEvaluator.claudeCode(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.detail ?? "").contains("usable access token"))
        XCTAssertEqual(report.overall, .fail)
    }

    // MARK: - Codex CLI

    func testCodexHealthy() {
        let input = CodexReadinessInput(
            isCLIInstalled: true,
            authFileExists: true,
            authFileReadable: true,
            authJSON: codexAuth(accessToken: makeJWT(expiration: 2_000_000)),
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.provider, .codexCli)
        XCTAssertEqual(report.overall, .pass)
        XCTAssertEqual(report.check("auth")?.level, .pass)
        assertNoSecretLeak(report)
    }

    func testCodexMissingAuthFileFailsWithLoginRecovery() {
        let input = CodexReadinessInput(
            isCLIInstalled: true,
            authFileExists: false,
            authFileReadable: false,
            authJSON: nil,
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("codex login"))
        XCTAssertEqual(report.overall, .fail)
    }

    func testCodexUnreadableAuthFileFailsAuth() {
        let input = CodexReadinessInput(
            isCLIInstalled: true,
            authFileExists: true,
            authFileReadable: false,
            authJSON: nil,
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertNotEqual(report.check("data")?.level, .pass)
    }

    func testCodexExpiredTokenFailsAuth() {
        let input = CodexReadinessInput(
            isCLIInstalled: true,
            authFileExists: true,
            authFileReadable: true,
            authJSON: codexAuth(accessToken: makeJWT(expiration: 500_000)), // past
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("codex login"))
    }

    func testCodexApiKeyModeDoesNotAuthorizeSubscriptionQuota() {
        // The quota endpoint uses the ChatGPT/Codex OAuth access token. An API
        // key may authorize platform APIs, but it cannot make this check healthy.
        let json = #"{"OPENAI_API_KEY":"sk-\#(secret)","tokens":null}"#.data(using: .utf8)
        let input = CodexReadinessInput(
            isCLIInstalled: true,
            authFileExists: true,
            authFileReadable: true,
            authJSON: json,
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertEqual(report.check("data")?.level, .warn)
        XCTAssertTrue((report.check("auth")?.detail ?? "").contains("subscription quota"))
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("codex login"))
        assertNoSecretLeak(report)
    }

    func testCodexBinaryMissingIsWarnNotFail() {
        // The app reads CODEX_HOME/auth.json directly, so a missing `codex` binary
        // is a soft warning, not a hard failure, when auth is otherwise present.
        let input = CodexReadinessInput(
            isCLIInstalled: false,
            authFileExists: true,
            authFileReadable: true,
            authJSON: codexAuth(accessToken: makeJWT(expiration: 2_000_000)),
            now: now
        )
        let report = ProviderReadinessEvaluator.codexCli(input)

        XCTAssertEqual(report.check("installed")?.level, .warn)
        XCTAssertEqual(report.check("auth")?.level, .pass)
        XCTAssertNotEqual(report.overall, .fail)
    }

    // MARK: - Cursor

    func testCursorHealthy() {
        let input = CursorReadinessInput(isInstalled: true, database: .tokenPresent, now: now)
        let report = ProviderReadinessEvaluator.cursor(input)

        XCTAssertEqual(report.provider, .cursor)
        XCTAssertEqual(report.overall, .pass)
        XCTAssertEqual(report.check("auth")?.level, .pass)
    }

    func testCursorUnreadableDatabaseFails() {
        let input = CursorReadinessInput(isInstalled: true, database: .unreadable, now: now)
        let report = ProviderReadinessEvaluator.cursor(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertEqual(report.check("data")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("Cursor"))
        XCTAssertEqual(report.overall, .fail)
    }

    func testCursorNotFoundFailsInstalled() {
        let input = CursorReadinessInput(isInstalled: false, database: .notFound, now: now)
        let report = ProviderReadinessEvaluator.cursor(input)

        XCTAssertEqual(report.check("installed")?.level, .fail)
        XCTAssertEqual(report.overall, .fail)
    }

    func testCursorMissingTokenFailsAuthButDataReadable() {
        let input = CursorReadinessInput(isInstalled: true, database: .missingToken, now: now)
        let report = ProviderReadinessEvaluator.cursor(input)

        XCTAssertEqual(report.check("auth")?.level, .fail)
        XCTAssertTrue((report.check("auth")?.recovery ?? "").contains("Cursor"))
        XCTAssertEqual(report.check("data")?.level, .pass)
    }

    // MARK: - Refresh + redaction (shared behavior)

    func testRefreshErrorSurfacesAndOverallDegrades() {
        let input = CursorReadinessInput(
            isInstalled: true,
            database: .tokenPresent,
            refreshError: "API error (HTTP 500)",
            now: now
        )
        let report = ProviderReadinessEvaluator.cursor(input)

        XCTAssertEqual(report.check("refresh")?.level, .fail)
        XCTAssertTrue((report.check("refresh")?.detail ?? "").contains("HTTP 500"))
        XCTAssertEqual(report.overall, .fail)
    }

    func testReportIsCodableForJSONOutput() throws {
        let report = ProviderReadinessEvaluator.cursor(
            CursorReadinessInput(isInstalled: true, database: .tokenPresent, now: now)
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ProviderReadiness.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testSummaryCountsWarningsSeparatelyFromAttention() {
        let ready = ProviderReadiness(
            provider: .claudeCode,
            checks: [ReadinessCheck(id: "ready", title: "Ready", level: .pass, detail: "Ready.")]
        )
        let warning = ProviderReadiness(
            provider: .codexCli,
            checks: [ReadinessCheck(id: "warning", title: "Warning", level: .warn, detail: "Warning.")]
        )
        let attention = ProviderReadiness(
            provider: .cursor,
            checks: [ReadinessCheck(id: "attention", title: "Attention", level: .fail, detail: "Attention.")]
        )

        let summary = ProviderReadinessSummary(reports: [ready, warning, attention])

        XCTAssertEqual(summary.ready, 1)
        XCTAssertEqual(summary.warning, 1)
        XCTAssertEqual(summary.attention, 1)
        XCTAssertEqual(summary.displayText, "1 ready · 1 warning · 1 needs attention")
    }

    // MARK: - Fixtures

    private func assertNoSecretLeak(_ report: ProviderReadiness, file: StaticString = #filePath, line: UInt = #line) {
        for check in report.checks {
            XCTAssertFalse(check.detail.contains(secret), "secret leaked into detail: \(check.detail)", file: file, line: line)
            XCTAssertFalse((check.recovery ?? "").contains(secret), "secret leaked into recovery", file: file, line: line)
        }
    }

    private func claudeCredentials(accessToken: String, expiresAtUnix: Int64) -> Data {
        let json = """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"refresh","expiresAt":\(expiresAtUnix),\
        "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default"}}
        """
        return Data(json.utf8)
    }

    private func codexAuth(accessToken: String, accountId: String = "acct_test") -> Data {
        let json = """
        {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\(accessToken)",\
        "refresh_token":"refresh","account_id":"\(accountId)"},"last_refresh":"2026-07-03T00:00:00Z"}
        """
        return Data(json.utf8)
    }

    private func makeJWT(expiration: TimeInterval) -> String {
        let payload = #"{"exp":\#(Int(expiration))}"#
        return "header.\(base64URL(payload)).signature"
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
