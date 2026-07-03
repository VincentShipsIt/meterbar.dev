import Foundation
import MeterBarShared

/// Gathers the real, on-disk facts each provider-readiness check needs
/// (binary on PATH, keychain credentials, `~/.codex/auth.json`, the Cursor
/// state database) and feeds them to the pure `ProviderReadinessEvaluator`.
///
/// This is the impure counterpart to the `MeterBarShared` core: it does the
/// filesystem / keychain / SQLite I/O the evaluators cannot. It lives in the app
/// library so both the app surfaces (Diagnostics view, empty-state checklist)
/// and `MeterBarCLI` (`meterbar doctor`) share one implementation — mirroring how
/// the CLI already reuses `SharedDataStore` / `CostSummaryStore`.
///
/// All provider error text is sanitized here (`sanitize`) so nothing that could
/// contain a token, account id, or raw response body reaches a pasteable report.
public enum ProviderReadinessInspector {
    /// Readiness reports for every provider, in stable display order.
    ///
    /// - Parameter refreshErrors: each provider's live last-refresh error. The app
    ///   passes these from the main actor (the services publish them); the CLI, a
    ///   one-shot process with no live refresh, passes none.
    public static func reports(
        refreshErrors: [ServiceType: ServiceError] = [:],
        now: Date = Date()
    ) -> [ProviderReadiness] {
        [
            claudeReport(refreshError: refreshErrors[.claudeCode], now: now),
            codexReport(refreshError: refreshErrors[.codexCli], now: now),
            cursorReport(refreshError: refreshErrors[.cursor], now: now)
        ]
    }

    // MARK: - Per-provider gathering

    /// How recent a cached Claude usage fetch must be to count as proof of a
    /// working CLI sign-in. Generous on purpose: any successful fetch implies
    /// login, and a later breakage surfaces through the refresh-error check.
    static let recentUsageFetchWindow: TimeInterval = 24 * 60 * 60

    static func claudeReport(refreshError: ServiceError? = nil, now: Date = Date()) -> ProviderReadiness {
        let input = ClaudeReadinessInput(
            isCLIInstalled: CLIBinaryLocator.isAvailable(command: "claude", overrideEnvVar: "CLAUDE_CLI_PATH"),
            credentialsJSON: ClaudeCodeLocalService.shared.credentialsData(),
            hasRecentUsageFetch: hasRecentClaudeUsageFetch(now: now),
            refreshError: sanitize(refreshError),
            now: now
        )
        return ProviderReadinessEvaluator.claudeCode(input)
    }

    /// Whether the shared metrics cache holds a Claude Code entry fetched
    /// recently. Fetches go through the `claude` CLI session, so this is direct
    /// sign-in evidence for the standard CLI-login flow, whose credentials the
    /// app cannot read (issue: keychain-only check false-negatived every
    /// `claude login` user). The cache is the same file `meterbar cost` and the
    /// widget already read, so the app and `meterbar doctor` agree.
    private static func hasRecentClaudeUsageFetch(now: Date) -> Bool {
        guard let metrics = SharedDataStore.shared.loadMetrics()[.claudeCode] else {
            return false
        }
        let age = now.timeIntervalSince(metrics.lastUpdated)
        return age >= 0 && age <= recentUsageFetchWindow
    }

    static func codexReport(refreshError: ServiceError? = nil, now: Date = Date()) -> ProviderReadiness {
        let fileManager = FileManager.default
        let path = "\(ServiceSupport.realHomeDirectory())/.codex/auth.json"
        let exists = fileManager.fileExists(atPath: path)
        let bytes = exists && fileManager.isReadableFile(atPath: path)
            ? fileManager.contents(atPath: path)
            : nil

        let input = CodexReadinessInput(
            isCLIInstalled: CLIBinaryLocator.isAvailable(command: "codex"),
            authFileExists: exists,
            authFileReadable: bytes != nil,
            authJSON: bytes,
            refreshError: sanitize(refreshError),
            now: now
        )
        return ProviderReadinessEvaluator.codexCli(input)
    }

    static func cursorReport(refreshError: ServiceError? = nil, now: Date = Date()) -> ProviderReadiness {
        let probe = CursorLocalService.shared.probeReadinessDatabase()
        let input = CursorReadinessInput(
            isInstalled: probe != .notFound || cursorAppPresent(),
            database: probe,
            refreshError: sanitize(refreshError),
            now: now
        )
        return ProviderReadinessEvaluator.cursor(input)
    }

    // MARK: - Helpers

    private static func cursorAppPresent() -> Bool {
        let fileManager = FileManager.default
        let home = ServiceSupport.realHomeDirectory()
        return fileManager.fileExists(atPath: "/Applications/Cursor.app")
            || fileManager.fileExists(atPath: "\(home)/Applications/Cursor.app")
    }

    /// Known connectivity messages that carry no account data and are safe to
    /// show verbatim (produced by `ServiceSupport.message(for:)`).
    private static let safeNetworkMessages: Set<String> = [
        "No internet connection",
        "DNS lookup failed",
        "Request timed out"
    ]

    /// Maps a `ServiceError` onto a short, paste-safe string. Crucially, an
    /// `.apiError` may embed a slice of the raw API response body
    /// (`ServiceSupport.validate`) — which can contain account data — so only a
    /// leading HTTP status code (or a whitelisted connectivity message) survives.
    static func sanitize(_ error: ServiceError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .notAuthenticated:
            return "Not authenticated"
        case .invalidURL:
            return "Invalid request URL"
        case .parsingError:
            return "Could not parse the provider response"
        case let .apiError(message):
            if safeNetworkMessages.contains(message) {
                return message
            }
            if let status = httpStatus(in: message) {
                return "API error (HTTP \(status))"
            }
            return "API error"
        }
    }

    /// The first `HTTP NNN` status code embedded in a message, if any.
    static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"HTTP \d{3}"#, options: .regularExpression) else {
            return nil
        }
        return Int(message[range].dropFirst("HTTP ".count))
    }
}
