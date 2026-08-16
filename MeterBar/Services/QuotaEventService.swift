import Foundation
import MeterBarShared

/// One provider/account row the Event Integrations settings can opt into.
/// Identity is the same UUID-or-`default` contract the webhook payload uses.
nonisolated struct QuotaEventSelectableAccount: Identifiable, Equatable, Sendable {
    let provider: ServiceType
    let accountID: String
    let name: String

    var id: String { "\(provider.rawValue):\(accountID)" }

    var selection: QuotaEventAccountSelection {
        QuotaEventAccountSelection(provider: provider, accountID: accountID)
    }
}

/// Account-aware inputs for Claude, Codex, and Grok. Flat providers still
/// arrive through the provider-wide metrics map.
nonisolated struct QuotaEventAccountInputs: Sendable {
    var claudeAccounts: [ClaudeCodeAccount] = []
    var claudeAccountMetrics: [UUID: UsageMetrics] = [:]
    var codexAccounts: [CodexAccount] = []
    var codexAccountMetrics: [UUID: UsageMetrics] = [:]
    var grokAccounts: [GrokAccount] = []
    var grokAccountMetrics: [UUID: UsageMetrics] = [:]
}

/// Builds the app-wide provider/account input without ever projecting
/// credential or filesystem configuration into the event model.
nonisolated enum QuotaEventSnapshotCatalog {
    static let flatProviders = ServiceType.allCases.filter {
        $0 != .claudeCode && $0 != .codexCli && $0 != .grok
    }

    static func snapshots(
        metrics: [ServiceType: UsageMetrics],
        accounts: QuotaEventAccountInputs,
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
            accounts: accounts.claudeAccounts.map {
                AccountMetricIdentity(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            },
            accountMetrics: accounts.claudeAccountMetrics,
            fallbackMetrics: metrics[.claudeCode],
            enabledServices: enabledServices
        )
        result += accountSnapshots(
            provider: .codexCli,
            accounts: accounts.codexAccounts.map {
                AccountMetricIdentity(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            },
            accountMetrics: accounts.codexAccountMetrics,
            fallbackMetrics: metrics[.codexCli],
            enabledServices: enabledServices
        )
        result += accountSnapshots(
            provider: .grok,
            accounts: accounts.grokAccounts.map {
                AccountMetricIdentity(id: $0.id, name: $0.name, isEnabled: $0.isEnabled)
            },
            accountMetrics: accounts.grokAccountMetrics,
            fallbackMetrics: metrics[.grok],
            enabledServices: enabledServices
        )
        return result.sorted {
            if $0.provider.sortOrder != $1.provider.sortOrder {
                return $0.provider.sortOrder < $1.provider.sortOrder
            }
            return $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending
        }
    }

    static func selectableAccounts(
        claudeAccounts: [ClaudeCodeAccount],
        codexAccounts: [CodexAccount],
        grokAccounts: [GrokAccount]
    ) -> [QuotaEventSelectableAccount] {
        let flat = flatProviders.map {
            QuotaEventSelectableAccount(provider: $0, accountID: "default", name: $0.displayName)
        }
        let claude = claudeAccounts.filter(\.isEnabled).map {
            QuotaEventSelectableAccount(
                provider: .claudeCode,
                accountID: $0.id.uuidString,
                name: $0.name
            )
        }
        let codex = codexAccounts.filter(\.isEnabled).map {
            QuotaEventSelectableAccount(
                provider: .codexCli,
                accountID: $0.id.uuidString,
                name: $0.name
            )
        }
        let grok = grokAccounts.filter(\.isEnabled).map {
            QuotaEventSelectableAccount(
                provider: .grok,
                accountID: $0.id.uuidString,
                name: $0.name
            )
        }
        return (claude + codex + grok + flat).sorted {
            if $0.provider.sortOrder != $1.provider.sortOrder {
                return $0.provider.sortOrder < $1.provider.sortOrder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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
