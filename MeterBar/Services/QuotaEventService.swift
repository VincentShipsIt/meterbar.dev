import Foundation
import MeterBarShared

/// Builds the app-wide provider/account input without ever projecting
/// credential or filesystem configuration into the event model.
nonisolated enum QuotaEventSnapshotCatalog {
    static let flatProviders = ServiceType.allCases.filter {
        $0 != .claudeCode && $0 != .codexCli
    }

    static func snapshots(
        metrics: [ServiceType: UsageMetrics],
        claudeAccounts: [ClaudeCodeAccount],
        claudeAccountMetrics: [UUID: UsageMetrics],
        codexAccounts: [CodexAccount],
        codexAccountMetrics: [UUID: UsageMetrics],
        enabledServices: Set<ServiceType>
    ) -> [QuotaEventSnapshot] {
        var result = flatProviders.compactMap { provider -> QuotaEventSnapshot? in
            guard enabledServices.contains(provider), let metric = metrics[provider] else {
                return nil
            }
            return QuotaEventSnapshot(
                provider: provider,
                account: QuotaEventAccount(id: "default", name: provider.displayName),
                metrics: metric
            )
        }

        result += accountSnapshots(
            provider: .claudeCode,
            accounts: claudeAccounts.map {
                AccountMetricIdentity(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            },
            accountMetrics: claudeAccountMetrics,
            fallbackMetrics: metrics[.claudeCode],
            enabledServices: enabledServices
        )
        result += accountSnapshots(
            provider: .codexCli,
            accounts: codexAccounts.map {
                AccountMetricIdentity(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            },
            accountMetrics: codexAccountMetrics,
            fallbackMetrics: metrics[.codexCli],
            enabledServices: enabledServices
        )
        return result.sorted {
            if $0.provider.sortOrder != $1.provider.sortOrder {
                return $0.provider.sortOrder < $1.provider.sortOrder
            }
            return $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending
        }
    }

    private static func accountSnapshots(
        provider: ServiceType,
        accounts: [AccountMetricIdentity],
        accountMetrics: [UUID: UsageMetrics],
        fallbackMetrics: UsageMetrics?,
        enabledServices: Set<ServiceType>
    ) -> [QuotaEventSnapshot] {
        guard enabledServices.contains(provider) else { return [] }
        let enabledAccounts = accounts.filter(\.isEnabled)
        return enabledAccounts.compactMap { account in
            let metric = accountMetrics[account.id]
                ?? (enabledAccounts.count == 1 ? fallbackMetrics : nil)
            guard let metric else { return nil }
            return QuotaEventSnapshot(
                provider: provider,
                account: QuotaEventAccount(id: account.id.uuidString, name: account.name),
                metrics: metric
            )
        }
    }

    private struct AccountMetricIdentity {
        let id: UUID
        let name: String
        let isEnabled: Bool
    }
}

nonisolated struct QuotaEventObservation: Sendable {
    let events: [QuotaEventPayload]
    let diagnostics: [QuotaEventDeliveryDiagnostic]
}

/// Serialized app-wide transition + delivery service. The actor boundary keeps
/// simultaneous refresh/account/settings publications from racing planner
/// state or delivering a transition twice.
actor QuotaEventService {
    private var planner: QuotaEventPlanner
    private let deliveryEngine: QuotaEventDeliveryEngine

    init(
        planner: QuotaEventPlanner = QuotaEventPlanner(),
        deliveryEngine: QuotaEventDeliveryEngine = QuotaEventDeliveryEngine()
    ) {
        self.planner = planner
        self.deliveryEngine = deliveryEngine
    }

    func observe(
        snapshots: [QuotaEventSnapshot],
        configuration: QuotaEventIntegrationConfiguration,
        now: Date = Date()
    ) async -> QuotaEventObservation {
        let events = planner.evaluate(snapshots: snapshots, now: now)
        let diagnostics = await deliveryEngine.deliver(
            payloads: events,
            configuration: configuration
        )
        return QuotaEventObservation(events: events, diagnostics: diagnostics)
    }
}
