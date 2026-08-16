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
        claudeDefaultAccountEnabled: Bool = true,
        claudeEnabledAccountMetrics: [UsageMetrics] = [],
        parseHealth: [ServiceType: ProviderParseHealthRecord]? = nil,
        cachedMetrics: [ServiceType: UsageMetrics]? = nil
    ) -> [ProviderReadiness] {
        reports(
            providers: providers,
            refreshErrors: refreshErrors,
            now: now,
            claudeDefaultAccountEnabled: claudeDefaultAccountEnabled,
            claudeEnabledAccountMetrics: claudeEnabledAccountMetrics,
            grokAccounts: nil,
            parseHealth: parseHealth,
            cachedMetrics: cachedMetrics
        )
    }

    static func reports(
        providers: Set<ServiceType> = Set(ServiceType.allCases),
        refreshErrors: [ServiceType: ServiceError] = [:],
        accountRefreshErrors: [ServiceType: [UUID: ServiceError]] = [:],
        now: Date = Date(),
        claudeAccounts: [ClaudeCodeAccount]? = nil,
        claudeAccountMetrics: [UUID: UsageMetrics] = [:],
        claudeDefaultAccountEnabled: Bool = true,
        claudeEnabledAccountMetrics: [UsageMetrics] = [],
        claudeCredentialsProbe: ((ClaudeCodeAccount) -> Data?)? = nil,
        codexAccounts: [CodexAccount]? = nil,
        codexAuthProbe: ((CodexAccount) -> (exists: Bool, readable: Bool, json: Data?))? = nil,
        grokAccounts: [GrokAccount]? = nil,
        grokAuthProbe: ((GrokAccount) -> (exists: Bool, readable: Bool))? = nil,
        parseHealth: [ServiceType: ProviderParseHealthRecord]? = nil,
        cachedMetrics: [ServiceType: UsageMetrics]? = nil,
        cachedAccountMetrics: [AccountUsageSnapshot]? = nil
    ) -> [ProviderReadiness] {
        let metrics = cachedMetrics ?? SharedDataStore.shared.loadMetrics()
        let accountSnapshots = cachedAccountMetrics ?? SharedDataStore.shared.loadAccountMetrics()
        let snapshotsByID = Dictionary(uniqueKeysWithValues: accountSnapshots.map { ($0.id, $0.metrics) })
        let configuration = UsageRefreshConfigurationStore.load()
        let configuredClaudeAccounts = claudeAccounts ?? configuration?.claudeAccounts
        let configuredCodexAccounts = codexAccounts
            ?? configuration?.codexAccounts
            ?? [.defaultAccount]
        let configuredGrokAccounts = grokAccounts
            ?? configuration?.grokAccounts
            ?? [.defaultAccount]
        let mergedClaudeMetrics = snapshotsByID.merging(claudeAccountMetrics) { _, incoming in incoming }
        let health = parseHealth ?? ProviderParseHealthStore.sharedRecords()

        let baseReports = reports(
            providers: providers,
            refreshErrors: refreshErrors,
            now: now,
            claudeReport: { error, date in
                claudeReports(
                    refreshError: error,
                    accountRefreshErrors: accountRefreshErrors[.claudeCode] ?? [:],
                    now: date,
                    accounts: configuredClaudeAccounts,
                    accountMetrics: mergedClaudeMetrics,
                    cachedMetrics: metrics[.claudeCode],
                    defaultAccountEnabled: claudeDefaultAccountEnabled,
                    enabledAccountMetrics: claudeEnabledAccountMetrics,
                    credentialsProbe: claudeCredentialsProbe
                )
            },
            codexReport: { error, date in
                codexReports(
                    refreshError: error,
                    accountRefreshErrors: accountRefreshErrors[.codexCli] ?? [:],
                    now: date,
                    accounts: configuredCodexAccounts,
                    accountMetrics: snapshotsByID,
                    authProbe: codexAuthProbe
                )
            },
            cursorReport: { error, date in [cursorReport(refreshError: error, now: date)] },
            openRouterReport: { error, _ in [openRouterReport(refreshError: error)] },
            grokReport: { error, date in
                grokReports(
                    refreshError: error,
                    accountRefreshErrors: accountRefreshErrors[.grok] ?? [:],
                    now: date,
                    accounts: configuredGrokAccounts,
                    accountMetrics: snapshotsByID,
                    authProbe: grokAuthProbe
                )
            }
        )
        return decorate(
            baseReports,
            health: health,
            metrics: metrics,
            accountMetrics: mergedClaudeMetrics.merging(snapshotsByID) { incoming, _ in incoming },
            now: now
        )
    }

    /// Injectable routing seam used to prove that disabled providers perform no
    /// filesystem, SQLite, or Keychain work. Production callers use the public
    /// overload above.
    static func reports(
        providers: Set<ServiceType>,
        refreshErrors: [ServiceType: ServiceError],
        now: Date,
        claudeReport: (ServiceError?, Date) -> [ProviderReadiness],
        codexReport: (ServiceError?, Date) -> [ProviderReadiness],
        cursorReport: (ServiceError?, Date) -> [ProviderReadiness],
        openRouterReport: (ServiceError?, Date) -> [ProviderReadiness] = { error, _ in
            [ProviderReadinessInspector.openRouterReport(refreshError: error)]
        },
        grokReport: (ServiceError?, Date) -> [ProviderReadiness] = { error, _ in
            [ProviderReadinessInspector.grokReport(refreshError: error)]
        }
    ) -> [ProviderReadiness] {
        ServiceType.allCases.flatMap { provider -> [ProviderReadiness] in
            guard providers.contains(provider) else { return [] }
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

    // swiftlint:disable:next function_parameter_count
    static func claudeReports(
        refreshError: ServiceError?,
        accountRefreshErrors: [UUID: ServiceError],
        now: Date,
        accounts: [ClaudeCodeAccount]?,
        accountMetrics: [UUID: UsageMetrics],
        cachedMetrics: UsageMetrics?,
        defaultAccountEnabled: Bool,
        enabledAccountMetrics: [UsageMetrics],
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(
            command: "claude",
            overrideEnvVar: "CLAUDE_CLI_PATH"
        ),
        isOAuthFallbackEnabled: () -> Bool = {
            ClaudeCodeLocalService.isOAuthUsageEnabled()
        },
        credentialsProbe: ((ClaudeCodeAccount) -> Data?)?
    ) -> [ProviderReadiness] {
        if let accounts {
            let enabled = accounts.filter(\.isEnabled)
            let reports = enabled.map { account in
                claudeReport(
                    identity: .account(.claudeCode, id: account.id, name: account.name),
                    refreshError: accountRefreshErrors[account.id] ?? (account.isDefault ? refreshError : nil),
                    now: now,
                    cachedMetrics: accountMetrics[account.id],
                    defaultAccountEnabled: account.isDefault,
                    enabledAccountMetrics: accountMetrics[account.id].map { [$0] } ?? [],
                    isCLIInstalled: isCLIInstalled,
                    isOAuthFallbackEnabled: isOAuthFallbackEnabled,
                    credentialsData: {
                        if let credentialsProbe {
                            return credentialsProbe(account)
                        }
                        return ClaudeCodeLocalService.shared.credentialsData(for: account)
                    }
                )
            }
            return pack(provider: .claudeCode, accountReports: reports)
        }

        return [
            claudeReport(
                refreshError: refreshError,
                now: now,
                cachedMetrics: cachedMetrics,
                defaultAccountEnabled: defaultAccountEnabled,
                enabledAccountMetrics: enabledAccountMetrics,
                isCLIInstalled: isCLIInstalled,
                isOAuthFallbackEnabled: isOAuthFallbackEnabled
            ),
        ]
    }

    static func claudeReport(
        identity: ReadinessIdentity = .provider(.claudeCode),
        refreshError: ServiceError? = nil,
        now: Date = Date(),
        cachedMetrics: @autoclosure () -> UsageMetrics? = SharedDataStore.shared.loadMetrics()[.claudeCode],
        defaultAccountEnabled: Bool = true,
        enabledAccountMetrics: [UsageMetrics] = [],
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(
            command: "claude",
            overrideEnvVar: "CLAUDE_CLI_PATH"
        ),
        isOAuthFallbackEnabled: () -> Bool = {
            ClaudeCodeLocalService.isOAuthUsageEnabled()
        },
        credentialsData: () -> Data? = { ClaudeCodeLocalService.shared.credentialsData() }
    ) -> ProviderReadiness {
        let hasRecentUsageFetch = enabledAccountMetrics.contains {
            hasRecentClaudeUsageFetch(metrics: $0, now: now)
        } || (
            defaultAccountEnabled
                && hasRecentClaudeUsageFetch(metrics: cachedMetrics(), now: now)
        )
        let credentialsJSON: Data?
        if hasRecentUsageFetch || !defaultAccountEnabled || !isOAuthFallbackEnabled() {
            credentialsJSON = nil
        } else {
            credentialsJSON = credentialsData()
        }
        let input = ClaudeReadinessInput(
            isCLIInstalled: isCLIInstalled,
            // Direct CLI evidence wins, so do not even query Keychain when a
            // recent successful fetch already proves readiness. The legacy
            // credential is likewise irrelevant while fallback or the default
            // account is disabled.
            credentialsJSON: credentialsJSON,
            hasRecentUsageFetch: hasRecentUsageFetch,
            refreshError: sanitize(refreshError),
            now: now
        )
        return ProviderReadinessEvaluator.claudeCode(input).withIdentity(identity)
    }

    /// Whether the shared metrics cache holds a Claude Code entry fetched
    /// recently. Fetches go through the `claude` CLI session, so this is direct
    /// sign-in evidence for the standard CLI-login flow, whose credentials the
    /// app cannot read (issue: keychain-only check false-negatived every
    /// `claude login` user). The cache is the same file `meterbar cost` and the
    /// widget already read, so the app and `meterbar doctor` agree.
    static func hasRecentClaudeUsageFetch(metrics: UsageMetrics?, now: Date) -> Bool {
        guard let metrics else {
            return false
        }
        let age = now.timeIntervalSince(metrics.lastUpdated)
        return age >= 0 && age <= recentUsageFetchWindow
    }

    static func codexReports(
        refreshError: ServiceError?,
        accountRefreshErrors: [UUID: ServiceError],
        now: Date,
        accounts: [CodexAccount],
        accountMetrics: [UUID: UsageMetrics],
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(command: "codex"),
        authProbe: ((CodexAccount) -> (exists: Bool, readable: Bool, json: Data?))?
    ) -> [ProviderReadiness] {
        let enabled = accounts.filter(\.isEnabled)
        let reports = enabled.map { account in
            codexReport(
                account: account,
                refreshError: accountRefreshErrors[account.id] ?? (account.isDefault ? refreshError : nil),
                now: now,
                isCLIInstalled: isCLIInstalled,
                authProbe: authProbe
            )
        }
        _ = accountMetrics
        return pack(provider: .codexCli, accountReports: reports)
    }

    static func codexReport(refreshError: ServiceError? = nil, now: Date = Date()) -> ProviderReadiness {
        codexReport(account: .defaultAccount, refreshError: refreshError, now: now)
    }

    static func codexReport(
        account: CodexAccount,
        refreshError: ServiceError? = nil,
        now: Date = Date(),
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(command: "codex"),
        authProbe: ((CodexAccount) -> (exists: Bool, readable: Bool, json: Data?))? = nil
    ) -> ProviderReadiness {
        let probe: (exists: Bool, readable: Bool, json: Data?)
        if let authProbe {
            probe = authProbe(account)
        } else {
            let fileManager = FileManager.default
            let path = CodexHomeDirectory.authFilePath(for: account)
            let exists = fileManager.fileExists(atPath: path)
            let bytes = exists && fileManager.isReadableFile(atPath: path)
                ? fileManager.contents(atPath: path)
                : nil
            probe = (exists, bytes != nil, bytes)
        }

        let input = CodexReadinessInput(
            isCLIInstalled: isCLIInstalled,
            authFileExists: probe.exists,
            authFileReadable: probe.readable,
            authJSON: probe.json,
            refreshError: sanitize(refreshError),
            now: now
        )
        return ProviderReadinessEvaluator.codexCli(input)
            .withIdentity(.account(.codexCli, id: account.id, name: account.name))
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

    static func grokReports(
        refreshError: ServiceError?,
        accountRefreshErrors: [UUID: ServiceError],
        now: Date,
        accounts: [GrokAccount],
        accountMetrics: [UUID: UsageMetrics],
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(
            command: "grok",
            overrideEnvVar: "GROK_CLI_PATH"
        ),
        authProbe: ((GrokAccount) -> (exists: Bool, readable: Bool))?
    ) -> [ProviderReadiness] {
        _ = now
        _ = accountMetrics
        return pack(
            provider: .grok,
            accountReports: grokAccountReports(
                accounts: accounts,
                refreshError: refreshError,
                accountRefreshErrors: accountRefreshErrors,
                isCLIInstalled: isCLIInstalled,
                authProbe: authProbe
            )
        )
    }

    static func grokReport(refreshError: ServiceError? = nil) -> ProviderReadiness {
        grokReport(accounts: [.defaultAccount], refreshError: refreshError)
    }

    static func grokReport(
        accounts: [GrokAccount],
        refreshError: ServiceError? = nil,
        isCLIInstalled: Bool = CLIBinaryLocator.isAvailable(
            command: "grok",
            overrideEnvVar: "GROK_CLI_PATH"
        ),
        authProbe: ((GrokAccount) -> (exists: Bool, readable: Bool))? = nil
    ) -> ProviderReadiness {
        let reports = pack(
            provider: .grok,
            accountReports: grokAccountReports(
                accounts: accounts,
                refreshError: refreshError,
                accountRefreshErrors: [:],
                isCLIInstalled: isCLIInstalled,
                authProbe: authProbe
            )
        )
        return reports.first { !$0.identity.isAccountScoped } ?? reports.first ?? ProviderReadiness(
            identity: .provider(.grok),
            checks: []
        )
    }

    private static func grokAccountReports(
        accounts: [GrokAccount],
        refreshError: ServiceError?,
        accountRefreshErrors: [UUID: ServiceError],
        isCLIInstalled: Bool,
        authProbe: ((GrokAccount) -> (exists: Bool, readable: Bool))?
    ) -> [ProviderReadiness] {
        accounts.filter(\.isEnabled).map { account in
            let probe: (exists: Bool, readable: Bool)
            if let authProbe {
                probe = authProbe(account)
            } else {
                let path = GrokHomeDirectory.authFilePath(for: account)
                let exists = FileManager.default.fileExists(atPath: path)
                probe = (exists, exists && FileManager.default.isReadableFile(atPath: path))
            }
            return ProviderReadinessEvaluator.grok(
                GrokReadinessInput(
                    isCLIInstalled: isCLIInstalled,
                    authFileExists: probe.exists,
                    authFileReadable: probe.readable,
                    refreshError: sanitize(
                        accountRefreshErrors[account.id] ?? (account.isDefault ? refreshError : nil)
                    )
                )
            )
            .withIdentity(.account(.grok, id: account.id, name: account.name))
        }
    }

    /// One account-scoped report when a single profile is enabled; otherwise the
    /// independent account reports plus one provider-wide aggregate.
    private static func pack(
        provider: ServiceType,
        accountReports: [ProviderReadiness]
    ) -> [ProviderReadiness] {
        guard !accountReports.isEmpty else {
            return [
                ProviderReadiness(
                    identity: .provider(provider),
                    checks: [
                        ReadinessCheck(
                            id: ReadinessCheckID.auth,
                            title: "Signed in",
                            level: .fail,
                            detail: "No enabled \(provider.displayName) profiles.",
                            recovery: "Enable a profile in MeterBar Settings."
                        ),
                    ]
                ),
            ]
        }
        guard accountReports.count > 1 else { return accountReports }
        let parseHealth = ProviderReadiness.aggregatedParseHealth(
            accountReports.compactMap { $0.check(ReadinessCheckID.parseHealth) }
        )
        let aggregate = ProviderReadiness.aggregate(
            provider: provider,
            accountReports: accountReports,
            parseHealth: parseHealth
        )
        return [aggregate] + accountReports
    }

    private static func decorate(
        _ reports: [ProviderReadiness],
        health: [ServiceType: ProviderParseHealthRecord],
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [UUID: UsageMetrics],
        now: Date
    ) -> [ProviderReadiness] {
        let decorated = reports.map { report in
            decorate(
                report,
                health: health,
                metrics: metrics,
                accountMetrics: accountMetrics,
                now: now
            )
        }
        return decorated.map { report in
            guard !report.identity.isAccountScoped else { return report }
            let siblings = decorated.filter {
                $0.identity.isAccountScoped && $0.provider == report.provider
            }
            guard !siblings.isEmpty else { return report }
            let parseHealth = ProviderReadiness.aggregatedParseHealth(
                siblings.compactMap { $0.check(ReadinessCheckID.parseHealth) }
            )
            let withoutParse = report.checks.filter { $0.id != ReadinessCheckID.parseHealth }
            return ProviderReadiness(identity: report.identity, checks: withoutParse + [parseHealth])
        }
    }

    private static func decorate(
        _ report: ProviderReadiness,
        health: [ServiceType: ProviderParseHealthRecord],
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [UUID: UsageMetrics],
        now: Date
    ) -> ProviderReadiness {
        if let accountID = report.identity.accountID {
            let accountMetric = accountMetrics[accountID]
            let record = health[report.provider]
            return ProviderReadiness(
                identity: report.identity,
                checks: reconciledRefreshChecks(
                    report.checks,
                    record: record,
                    metrics: accountMetric ?? metrics[report.provider]
                ) + [
                    accountParseHealthCheck(
                        report: report,
                        metrics: accountMetric,
                        record: record,
                        providerMetrics: metrics[report.provider],
                        now: now
                    ),
                ]
            )
        }

        let record = health[report.provider]
        let providerMetrics = metrics[report.provider]
        return ProviderReadiness(
            identity: report.identity,
            checks: reconciledRefreshChecks(
                report.checks,
                record: record,
                metrics: providerMetrics
            ) + [parseHealthCheck(record, metrics: providerMetrics, now: now)]
        )
    }

    private static func accountParseHealthCheck(
        report: ProviderReadiness,
        metrics: UsageMetrics?,
        record: ProviderParseHealthRecord?,
        providerMetrics: UsageMetrics?,
        now: Date
    ) -> ReadinessCheck {
        let title = "Usage data"
        let threshold = "Data is considered stale after 2 hours."
        let refresh = report.check(ReadinessCheckID.refresh)
        let refreshFailed = refresh?.level == .fail
        if refreshFailed, isParseFailureDetail(refresh?.detail) {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .fail,
                detail: "MeterBar couldn't read the latest usage — the provider's "
                    + "response format changed. \(threshold)",
                recovery: "Refresh once more, then copy this Diagnostics report if it persists."
            )
        }

        let hasRecentSuccess = metrics.map {
            let age = now.timeIntervalSince($0.lastUpdated)
            return age >= 0 && age <= ProviderParseHealthRecord.staleAfter
        } ?? false
        if hasRecentSuccess {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .pass,
                detail: "Showing usage from a recent successful refresh. \(threshold)"
            )
        }

        if refreshFailed {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .warn,
                detail: "The last refresh failed and there's no recent usage to fall back on. \(threshold)",
                recovery: "Refresh the provider and review any new error."
            )
        }
        if metrics != nil {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .warn,
                detail: "Usage data is older than the 2-hour freshness window.",
                recovery: "Refresh the provider and review any new error."
            )
        }
        return parseHealthCheck(record, metrics: providerMetrics, now: now)
    }

    private static func isParseFailureDetail(_ detail: String?) -> Bool {
        guard let detail else { return false }
        let lowered = detail.lowercased()
        return lowered.contains("could not parse")
            || lowered.contains("format")
            || detail.contains(GrokRefreshFailure.unparseableResponse.message)
            || ClaudeCodeParseFailure.messages.contains(where: detail.contains)
    }

    // MARK: - Helpers

    private static func parseHealthCheck(
        _ record: ProviderParseHealthRecord?,
        metrics: UsageMetrics?,
        now: Date
    ) -> ReadinessCheck {
        // Plain-English label. "Provider format health" was internal jargon; a
        // user reads this row to answer "is my usage current?", so the title
        // says exactly that and the detail carries the specifics.
        let title = "Usage data"
        let threshold = "Data is considered stale after 2 hours."

        let latestSuccess = [record?.lastSuccess, metrics?.lastUpdated].compactMap { $0 }.max()
        let latestFailureIsCurrent = record.map {
            $0.consecutiveFailures > 0
                && $0.lastAttempt > (latestSuccess ?? .distantPast)
        } ?? false

        guard record != nil || latestSuccess != nil else {
            return ReadinessCheck(
                id: ReadinessCheckID.parseHealth,
                title: title,
                level: .warn,
                detail: "No refresh outcome has been recorded yet. \(threshold)"
            )
        }

        // A genuine format drift is a real, immediate failure worth surfacing —
        // MeterBar reverse-engineers these feeds, so a shape change breaks reads.
        if latestFailureIsCurrent, record?.lastFailureWasShapeMismatch == true {
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
        if latestFailureIsCurrent,
           let record,
           record.consecutiveFailures >= ProviderParseHealthRecord.sustainedFailureCount {
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
            guard let lastSuccess = latestSuccess else { return false }
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
        if latestFailureIsCurrent {
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

    private static func reconciledRefreshChecks(
        _ checks: [ReadinessCheck],
        record: ProviderParseHealthRecord?,
        metrics: UsageMetrics?
    ) -> [ReadinessCheck] {
        guard let record,
              record.consecutiveFailures > 0,
              record.lastAttempt > (metrics?.lastUpdated ?? record.lastSuccess ?? .distantPast),
              checks.first(where: { $0.id == ReadinessCheckID.refresh })?.level == .pass else {
            return checks
        }

        let level: ReadinessLevel = record.lastFailureWasShapeMismatch
            || record.consecutiveFailures >= ProviderParseHealthRecord.sustainedFailureCount
            ? .fail
            : .warn
        let replacement = ReadinessCheck(
            id: ReadinessCheckID.refresh,
            title: "Last refresh",
            level: level,
            detail: "The latest recorded refresh failed; cached usage was preserved.",
            recovery: "Refresh in MeterBar and review the Usage data check."
        )
        return checks.map { $0.id == ReadinessCheckID.refresh ? replacement : $0 }
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
        case let .parsingError(detail):
            // Same rule as the API messages below: only interpolation-free
            // strings MeterBar authored survive, because a parse detail is the
            // one place raw provider output could otherwise leak into a
            // pasteable diagnostics report.
            if let detail, ClaudeCodeParseFailure.messages.contains(detail) {
                return detail
            }
            return "Could not parse the provider response"
        case let .apiError(message):
            if safeNetworkMessages.contains(message) {
                return message
            }
            // Fixed, interpolation-free strings the Grok transport emits in place
            // of provider text. Collapsing these to "API error" would throw away
            // the one thing that tells a user whether to run `grok login`, update
            // the CLI, or just refresh again.
            if GrokRefreshFailure.messages.contains(message) {
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
