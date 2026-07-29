import Foundation
import MeterBarShared

/// One provider/account quota group plus the deferred activity probe that
/// decides how recently it was used. Extracted from `MeterBarApp.swift`
/// (C1 split); `private` was widened to internal so the probe fan-out can be
/// unit-tested.
struct StatusLimitProbeRequest: Sendable {
    let seeds: [StatusLimitCandidateSeed]
    let probe: @Sendable () -> Date?
}

/// The main-actor inputs a request is built from, gathered before the probe
/// runs off the main actor. Widened from `private` alongside the request.
struct StatusLimitSource {
    let service: ServiceType
    let accountID: UUID?
    /// `<service>:<accountID>` for the multi-account providers, nil for the
    /// single-account ones. `var` so the memberwise init defaults it to nil.
    var accountKey: String?
    let autoSelectionKey: String?
    let displayName: String
    let metrics: UsageMetrics
}

/// Builds the status-item candidate set. Extracted from `MeterBarApp.swift`
/// (C1 split).
///
/// Two deliberate signature changes, both for testability: the per-provider
/// metric fallbacks (`claudeMetrics` / `codexMetrics`) used to read
/// `UsageDataManager.shared` inline, and now take the account map and provider
/// snapshot as parameters. The rules they encode are unchanged.
nonisolated enum StatusLimitProbeRequestBuilder {
    /// Every enabled account/provider quota that may own the menu bar title,
    /// each carrying a deferred probe for its latest on-disk activity so
    /// `StatusItemLimitSelector` can follow the accounts actually in use.
    @MainActor
    static func requests(metrics: [ServiceType: UsageMetrics]) -> [StatusLimitProbeRequest] {
        let visibility = ProviderVisibilityStore.shared
        var requests: [StatusLimitProbeRequest] = []

        if visibility.isEnabled(.claudeCode) {
            for account in ClaudeCodeAccountStore.shared.enabledAccounts {
                guard let accountMetrics = claudeMetrics(
                    for: account,
                    accountMetrics: UsageDataManager.shared.claudeCodeAccountMetrics,
                    providerMetrics: metrics[.claudeCode]
                ) else { continue }
                let configDirectory = account.configDirectory
                let source = StatusLimitSource(
                    service: .claudeCode,
                    accountID: account.id,
                    accountKey: MenuBarAccountKey.make(service: .claudeCode, accountID: account.id),
                    autoSelectionKey: "claude:\(account.id.uuidString)",
                    displayName: "\(account.name) (\(ServiceType.claudeCode.displayName))",
                    metrics: accountMetrics
                )
                requests.append(request(
                    source: source,
                    probe: { AccountActivityInspector.claudeCodeActivity(configDirectory: configDirectory) }
                ))
            }
        }
        if visibility.isEnabled(.codexCli) {
            let enabledAccounts = CodexAccountStore.shared.enabledAccounts
            for account in enabledAccounts {
                guard let accountMetrics = codexMetrics(
                    for: account,
                    enabledAccountCount: enabledAccounts.count,
                    accountMetrics: UsageDataManager.shared.codexAccountMetrics,
                    providerMetrics: metrics[.codexCli]
                ) else { continue }
                let homeDirectory = account.homeDirectory
                let source = StatusLimitSource(
                    service: .codexCli,
                    accountID: account.id,
                    accountKey: MenuBarAccountKey.make(service: .codexCli, accountID: account.id),
                    autoSelectionKey: "codex:\(account.id.uuidString)",
                    displayName: "\(account.name) (\(ServiceType.codexCli.displayName))",
                    metrics: accountMetrics
                )
                requests.append(request(
                    source: source,
                    probe: { AccountActivityInspector.codexCliActivity(homeDirectory: homeDirectory) }
                ))
            }
        }
        if visibility.isEnabled(.cursor), let cursorMetrics = metrics[.cursor] {
            let source = StatusLimitSource(
                service: .cursor,
                accountID: nil,
                autoSelectionKey: "cursor",
                displayName: ServiceType.cursor.displayName,
                metrics: cursorMetrics
            )
            requests.append(request(
                source: source,
                probe: { AccountActivityInspector.cursorActivity() }
            ))
        }
        if visibility.isEnabled(.openRouter), let openRouterMetrics = metrics[.openRouter] {
            let source = StatusLimitSource(
                service: .openRouter,
                accountID: nil,
                // No activity signal on disk, so OpenRouter never auto-wins the
                // title; it can still be pinned explicitly.
                autoSelectionKey: nil,
                displayName: ServiceType.openRouter.displayName,
                metrics: openRouterMetrics
            )
            requests.append(request(
                source: source,
                probe: { nil }
            ))
        }

        return requests
    }

    @MainActor
    static func request(
        source: StatusLimitSource,
        probe: @escaping @Sendable () -> Date?
    ) -> StatusLimitProbeRequest {
        let seeds = StatusItemLimitCandidateBuilder.seeds(
            service: source.service,
            accountID: source.accountID,
            accountKey: source.accountKey,
            autoSelectionKey: source.autoSelectionKey,
            displayName: source.displayName,
            limits: ProviderSnapshotBuilder.limits(for: source.metrics, service: source.service),
            lastUpdated: source.metrics.lastUpdated
        )
        return StatusLimitProbeRequest(seeds: seeds, probe: probe)
    }

    /// Runs each request's probe exactly once and stamps the result onto every
    /// seed it covers. Safe to call off the main actor — that is the point.
    static func candidates(from requests: [StatusLimitProbeRequest]) -> [StatusLimitCandidate] {
        requests.flatMap { request in
            let lastActivity = request.probe()
            return request.seeds.map { seed in
                StatusLimitCandidate(
                    key: seed.key,
                    pinKey: seed.pinKey,
                    service: seed.service,
                    accountKey: seed.accountKey,
                    displayName: seed.displayName,
                    windowID: seed.windowID,
                    windowName: seed.windowName,
                    limit: seed.limit,
                    lastUpdated: seed.lastUpdated,
                    lastActivity: lastActivity,
                    isAutoSelectable: seed.isAutoSelectable
                )
            }
        }
    }

    /// Per-account metrics win; the provider-wide snapshot only backs the
    /// default account, which is the one that reads `~/.claude`.
    static func claudeMetrics(
        for account: ClaudeCodeAccount,
        accountMetrics: [UUID: UsageMetrics],
        providerMetrics: UsageMetrics?
    ) -> UsageMetrics? {
        accountMetrics[account.id] ?? (account.isDefault ? providerMetrics : nil)
    }

    /// Codex is stricter than Claude: the provider-wide snapshot only backs the
    /// default account while it is the *only* enabled one and no per-account
    /// metrics exist at all, so a multi-profile setup never double-counts the
    /// default profile's quota.
    static func codexMetrics(
        for account: CodexAccount,
        enabledAccountCount: Int,
        accountMetrics: [UUID: UsageMetrics],
        providerMetrics: UsageMetrics?
    ) -> UsageMetrics? {
        let fallbackMetrics = account.isDefault
            && enabledAccountCount == 1
            && accountMetrics.isEmpty
            ? providerMetrics
            : nil
        return accountMetrics[account.id] ?? fallbackMetrics
    }
}
