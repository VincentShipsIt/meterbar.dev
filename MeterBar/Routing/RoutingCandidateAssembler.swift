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
    ///     case nothing is known to be hidden.
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
            let configured = configuredAccounts(for: service, in: configuration)
            let snapshots = accounts.filter { $0.metrics.service == service }

            // No per-account snapshots (Cursor, or a cache written before the
            // account cache existed): the provider-wide snapshot speaks for
            // the provider. It is off only when every configured account is.
            guard !snapshots.isEmpty else {
                let allDisabled = !configured.isEmpty && configured.allSatisfy { !$0.isEnabled }
                candidates.append(RoutingCandidate(
                    service: service,
                    isEnabled: !allDisabled,
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
                // A disabled account with no snapshot has nothing to say.
                if !account.isEnabled, snapshot == nil { continue }
                candidates.append(RoutingCandidate(
                    service: service,
                    accountID: account.id,
                    accountName: snapshot?.name ?? account.name,
                    isEnabled: account.isEnabled,
                    displayOrder: order,
                    metrics: snapshot?.metrics,
                    health: serviceHealth
                ))
            }
            // A cached account the configuration no longer lists still has a
            // real snapshot; keep it, after the configured ones.
            for (offset, snapshot) in snapshots.enumerated() where !seen.contains(snapshot.id) {
                candidates.append(RoutingCandidate(
                    service: service,
                    accountID: snapshot.id,
                    accountName: snapshot.name,
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
        guard let record else { return .healthy }
        if record.isSustainedOrParseFailure { return .failing }
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
        guard let configuration else { return [] }
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
        case .cursor:
            return []
        }
    }
}
