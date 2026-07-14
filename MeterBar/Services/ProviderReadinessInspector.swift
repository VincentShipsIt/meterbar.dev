import Foundation
import MeterBarShared

/// Gathers the real, on-disk facts each provider-readiness check needs
/// (binary on PATH, keychain credentials, `CODEX_HOME/auth.json`, the Cursor
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
nonisolated public enum ProviderReadinessInspector {
    /// Readiness reports for the requested providers, in stable display order.
    ///
    /// - Parameter refreshErrors: each provider's live last-refresh error. The app
    ///   passes these from the main actor (the services publish them); the CLI, a
    ///   one-shot process with no live refresh, passes none.
    public static func reports(
        providers: Set<ServiceType> = Set(ServiceType.allCases),
        refreshErrors: [ServiceType: ServiceError] = [:],
        now: Date = Date(),
        parseHealth: [ServiceType: ProviderParseHealthRecord]? = nil
    ) -> [ProviderReadiness] {
        let baseReports = reports(
            providers: providers,
            refreshErrors: refreshErrors,
            now: now,
            claudeReport: { claudeReport(refreshError: $0, now: $1) },
            codexReport: { codexReport(refreshError: $0, now: $1) },
            cursorReport: { cursorReport(refreshError: $0, now: $1) },
            openRouterReport: { error, _ in openRouterReport(refreshError: error) },
            grokReport: { error, _ in grokReport(refreshError: error) }
        )
        let health = parseHealth ?? ProviderParseHealthStore.sharedRecords()
        return baseReports.map { report in
            ProviderReadiness(
                provider: report.provider,
                checks: report.checks + [parseHealthCheck(health[report.provider], now: now)]
            )
        }
    }

    /// Injectable routing seam used to prove that disabled providers perform no
    /// filesystem, SQLite, or Keychain work. Production callers use the public
    /// overload above.
    static func reports(
        providers: Set<ServiceType>,
        refreshErrors: [ServiceType: ServiceError],
        now: Date,
        claudeReport: (ServiceError?, Date) -> ProviderReadiness,
        codexReport: (ServiceError?, Date) -> ProviderReadiness,
        cursorReport: (ServiceError?, Date) -> ProviderReadiness,
        openRouterReport: (ServiceError?, Date) -> ProviderReadiness = { error, _ in
            ProviderReadinessInspector.openRouterReport(refreshError: error)
        },
        grokReport: (ServiceError?, Date) -> ProviderReadiness = { error, _ in
            ProviderReadinessInspector.grokReport(refreshError: error)
        }
    ) -> [ProviderReadiness] {
        ServiceType.allCases.compactMap { provider in
            guard providers.contains(provider) else { return nil }
            switch provider {
            case .claudeCode:
                return claudeReport(refreshErrors[provider], now)
            case .codexCli:
                return codexReport(refreshErrors[provider], now)
            case .cursor:
                return cursorReport(refreshErrors[provider], now)
            case .openRouter:
                return openRouterReport(refreshErrors[provider], now)
            case .grok:
                return grokReport(refreshErrors[provider], now)
            }
        }
    }

    // MARK: - Per-provider gathering

    /// How recent a cached Claude usage fetch must be to count as proof of a
    /// working CLI sign-in. Generous on purpose: any successful fetch implies
    /// login, and a later breakage surfaces through the refresh-error check.
    static let recentUsageFetchWindow: TimeInterval = 24 * 60 * 60

    static func claudeReport(
        refreshError: ServiceError? = nil,
        now: Date = Date(),
        cachedMetrics: UsageMetrics? = SharedDataStore.shared.loadMetrics()[.claudeCode],
        isOAuthFallbackEnabled: () -> Bool = {
            ClaudeCodeLocalService.isOAuthUsageEnabled()
        },
        credentialsData: () -> Data? = { ClaudeCodeLocalService.shared.credentialsData() }
    ) -> ProviderReadiness {
        let hasRecentUsageFetch = hasRecentClaudeUsageFetch(metrics: cachedMetrics, now: now)
        let credentialsJSON: Data?
        if hasRecentUsageFetch || !isOAuthFallbackEnabled() {
            credentialsJSON = nil
        } else {
            credentialsJSON = credentialsData()
        }
        let input = ClaudeReadinessInput(
            isCLIInstalled: CLIBinaryLocator.isAvailable(command: "claude", overrideEnvVar: "CLAUDE_CLI_PATH"),
            // Direct CLI evidence wins, so do not even query Keychain when a
            // recent successful fetch already proves readiness. The legacy
            // credential is likewise irrelevant while fallback is disabled.
            credentialsJSON: credentialsJSON,
            hasRecentUsageFetch: hasRecentUsageFetch,
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
    private static func hasRecentClaudeUsageFetch(metrics: UsageMetrics?, now: Date) -> Bool {
        guard let metrics else {
            return false
        }
        let age = now.timeIntervalSince(metrics.lastUpdated)
        return age >= 0 && age <= recentUsageFetchWindow
    }

    static func codexReport(refreshError: ServiceError? = nil, now: Date = Date()) -> ProviderReadiness {
        let fileManager = FileManager.default
        let path = CodexHomeDirectory.authFilePath()
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

    static func openRouterReport(
        refreshError: ServiceError? = nil,
        hasAPIKey: () -> Bool = { KeychainManager.shared.hasKey(key: OpenRouterService.keychainKey) }
    ) -> ProviderReadiness {
        ProviderReadinessEvaluator.openRouter(
            OpenRouterReadinessInput(
                hasAPIKey: hasAPIKey(),
                refreshError: sanitize(refreshError)
            )
        )
    }

    static func grokReport(refreshError: ServiceError? = nil) -> ProviderReadiness {
        let fileManager = FileManager.default
        let authPath = GrokCLIUsageService.authFilePath()
        let authExists = fileManager.fileExists(atPath: authPath)
        return ProviderReadinessEvaluator.grok(
            GrokReadinessInput(
                isCLIInstalled: CLIBinaryLocator.isAvailable(command: "grok", overrideEnvVar: "GROK_CLI_PATH"),
                authFileExists: authExists,
                authFileReadable: authExists && fileManager.isReadableFile(atPath: authPath),
                refreshError: sanitize(refreshError)
            )
        )
    }

    // MARK: - Helpers

    private static func parseHealthCheck(_ record: ProviderParseHealthRecord?, now: Date) -> ReadinessCheck {
        // Plain-English label. "Provider format health" was internal jargon; a
        // user reads this row to answer "is my usage current?", so the title
        // says exactly that and the detail carries the specifics.
        let title = "Usage data"
        let threshold = "Data is considered stale after 2 hours."

        guard let record else {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .warn,
                detail: "No refresh outcome has been recorded yet. \(threshold)"
            )
        }

        // A genuine format drift is a real, immediate failure worth surfacing —
        // MeterBar reverse-engineers these feeds, so a shape change breaks reads.
        if record.lastFailureWasShapeMismatch {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .fail,
                detail: "MeterBar couldn't read the latest usage — the provider's "
                    + "response format changed. \(threshold)",
                recovery: "Refresh once more, then copy this Diagnostics report if it persists."
            )
        }
        // Failures piling up mean the data on screen is genuinely going stale.
        if record.consecutiveFailures >= ProviderParseHealthRecord.sustainedFailureCount {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .fail,
                detail: "\(record.consecutiveFailures) refreshes in a row failed. \(threshold)",
                recovery: "Check the provider connection and refresh again."
            )
        }

        // Freshness decides the rest — not a single miss. MeterBar retries on
        // every refresh, so one stray failure while recent data is still on
        // screen is invisible to the user and not worth a warning. (Warning on
        // it is exactly what made this row light up "all the time".)
        let hasRecentSuccess: Bool = {
            guard let lastSuccess = record.lastSuccess else { return false }
            return now.timeIntervalSince(lastSuccess) <= ProviderParseHealthRecord.staleAfter
        }()

        if hasRecentSuccess {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .pass,
                detail: "Showing usage from a recent successful refresh. \(threshold)"
            )
        }

        // No recent success to fall back on: now the failure (or the age) matters.
        if record.consecutiveFailures > 0 {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .warn,
                detail: "The last refresh failed and there's no recent usage to fall back on. \(threshold)",
                recovery: "Refresh the provider and review any new error."
            )
        }
        return ReadinessCheck(
            id: ReadinessCheckID.parseHealth,
            title: title,
            level: .warn,
            detail: "Usage data is older than the 2-hour freshness window.",
            recovery: "Refresh the provider and review any new error."
        )
    }

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
        "Request timed out",
        "Request cancelled",
        "Network connection lost",
        "Could not connect to provider",
        "Secure connection failed",
        "Network request failed"
    ]

    /// Maps a `ServiceError` onto a short, paste-safe string. API messages stay
    /// generic here as defense in depth; only a leading HTTP status code (or a
    /// whitelisted connectivity message) survives.
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
