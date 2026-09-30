import Foundation
import MeterBarShared

/// Turns the caches MeterBar already keeps into the router's candidates.
///
/// Reads nothing itself: every input is a value the caller loaded, so the
/// assembly is testable without an App Group container, and it can carry no
/// credential, path, or email because none of its inputs do.
nonisolated enum RoutingCandidateAssembler {
    /// - Parameters:
    ///   - metrics: the provider-wide snapshots (`loadMetrics()`).
    ///   - accounts: per-account snapshots (`loadAccountMetrics()`).
    ///   - configuration: which providers are hidden and which accounts exist
    ///     and are enabled. `nil` when the app has never written it, in which
    ///     case nothing is known to be hidden. Providers without routing
    ///     support stay disabled until a readable configuration confirms visibility.
    ///   - health: persisted fetch and parse health per provider.
    static func assemble(
        metrics: [ServiceType: UsageMetrics],
        accounts: [AccountUsageSnapshot],
        configuration: UsageRefreshConfigurationStore.Snapshot?,
        health: [ServiceType: ProviderParseHealthRecord]
    ) -> [RoutingCandidate] {
        let hidden = configuration?.hiddenServices ?? []
        var candidates: [RoutingCandidate] = []

        let services = ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        for service in services where !hidden.contains(service) {
            let serviceHealth = routingHealth(health[service])
            if !service.supportsWorkloadRouting {
                candidates.append(RoutingCandidate(
                    service: service,
                    isEnabled: configuration != nil,
                    metrics: metrics[service],
                    health: serviceHealth
                ))
                continue
            }
            let configured = configuredAccounts(for: service, in: configuration)
            let snapshots = service == .cursor ? [] : accounts.filter { $0.metrics.service == service }

            // No per-account snapshots (Cursor, or a cache written before the
            // account cache existed): the provider-wide snapshot speaks for
            // the provider. A present configuration with no enabled account is
            // authoritative; only a missing legacy configuration permits an
            // unknown account-managed provider. Cursor has no account list.
            guard !snapshots.isEmpty else {
                let isEnabled = service == .cursor || configuration == nil || configured.contains { $0.isEnabled }
                candidates.append(RoutingCandidate(
                    service: service,
                    isEnabled: isEnabled,
                    metrics: metrics[service],
                    health: serviceHealth
                ))
                continue
            }

            // Account snapshots exist, so the provider is routed per account;
            // adding its provider-wide roll-up as well would count one quota
            // twice.
            var seen = Set<UUID>()
            for (order, account) in configured.enumerated() {
                seen.insert(account.id)
                let snapshot = snapshots.first { $0.id == account.id }
                candidates.append(RoutingCandidate(
                    service: service,
                    accountID: account.id,
                    accountName: account.name,
                    isEnabled: account.isEnabled,
                    displayOrder: order,
                    metrics: snapshot?.metrics,
                    health: serviceHealth
                ))
            }
            // Keep removed accounts explainable, but a cache cannot revive
            // membership absent from an authoritative configuration. Sort the
            // legacy/orphan tail by UUID so cache serialization order cannot
            // change account priority or rejection order.
            let unlisted = snapshots.filter { !seen.contains($0.id) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            for (offset, snapshot) in unlisted.enumerated() {
                candidates.append(RoutingCandidate(
                    service: service,
                    accountID: snapshot.id,
                    accountName: snapshot.name,
                    isEnabled: configuration == nil,
                    displayOrder: configured.count + offset,
                    metrics: snapshot.metrics,
                    health: serviceHealth
                ))
            }
        }
        return candidates
    }

    /// Sustained failures reject the provider; any recent failure scores it down.
    static func routingHealth(_ record: ProviderParseHealthRecord?) -> RoutingProviderHealth {
        guard let record else {
            return .healthy
        }
        if record.isSustainedOrParseFailure {
            return .failing
        }
        return record.consecutiveFailures > 0 ? .degraded : .healthy
    }

    private struct ConfiguredAccount {
        let id: UUID
        let name: String
        let isEnabled: Bool
    }

    private static func configuredAccounts(
        for service: ServiceType,
        in configuration: UsageRefreshConfigurationStore.Snapshot?
    ) -> [ConfiguredAccount] {
        guard let configuration else {
            return []
        }
        switch service {
        case .claudeCode:
            return configuration.claudeAccounts.map {
                ConfiguredAccount(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            }
        case .codexCli:
            return configuration.codexAccounts.map {
                ConfiguredAccount(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            }
        case .grok:
            return configuration.grokAccounts.map {
                ConfiguredAccount(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            }
        case .openRouter:
            return configuration.openRouterAccounts.map {
                ConfiguredAccount(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            }
        case .cursor,
             .kimiCode,
             .zaiCodingPlan,
             .githubCopilot:
            return []
        }
    }
}
