import Foundation

/// One cache whose only key is a provider plus an explicit account scope.
/// Provider-wide summaries never satisfy an account lookup.
public struct UsageCache: Sendable {
    private var entries: [ProviderAccount: UsageMetrics] = [:]

    public init() {}

    public subscript(account: ProviderAccount) -> UsageMetrics? {
        get { entries[account] }
        set {
            guard let newValue else {
                entries.removeValue(forKey: account)
                return
            }
            guard newValue.service == account.service, !newValue.hasInvalidBlockingQuota else { return }
            entries[account] = newValue
        }
    }

    /// A display projection, never an account fallback.
    public var providerMetrics: [ServiceType: UsageMetrics] {
        entries.reduce(into: [:]) { result, entry in
            if entry.key.scope == .providerWide { result[entry.key.service] = entry.value }
        }
    }

    public func accounts(for service: ServiceType) -> [UUID: UsageMetrics] {
        entries.reduce(into: [:]) { result, entry in
            guard entry.key.service == service, case let .account(id) = entry.key.scope else { return }
            result[id.value] = entry.value
        }
    }

    public mutating func replaceProviderMetrics(_ metrics: [ServiceType: UsageMetrics]) {
        entries = entries.filter { $0.key.scope != .providerWide }
        for (service, metric) in metrics {
            self[ProviderAccount(service: service, scope: .providerWide)] = metric
        }
    }

    public mutating func replaceAccounts(_ metrics: [UUID: UsageMetrics], for service: ServiceType) {
        entries = entries.filter { entry in
            guard entry.key.service == service else { return true }
            if case .account = entry.key.scope { return false }
            return true
        }
        for (id, metric) in metrics {
            self[ProviderAccount(service: service, scope: .account(AccountID(id)))] = metric
        }
    }
}
