import Foundation
import MeterBarShared

/// The `--provider` / `--account` selection shared by `meterbar usage` and
/// `serve /usage`.
///
/// Provider matching stays on `CLIProviderFilter`. Account matching is
/// exact-token — the account id (UUID string) or the exact account name —
/// so a short name cannot silently select a longer one.
nonisolated public struct UsageCLISelection: Sendable {
    /// Printed when `--account` / `?account=` matches nothing.
    public static let noMatchingAccountsMessage = "No matching accounts."

    public let metrics: [ServiceType: UsageMetrics]
    public let accounts: [AccountUsageSnapshot]
    public let providerFilter: String?
    public let accountFilter: String?

    public init(
        metrics: [ServiceType: UsageMetrics],
        accounts: [AccountUsageSnapshot],
        providerFilter: String?,
        accountFilter: String?
    ) {
        self.metrics = metrics
        self.accounts = accounts
        self.providerFilter = providerFilter
        self.accountFilter = accountFilter
    }

    /// Applies the same filters the CLI flags and the serve query parameters use.
    public static func resolve(
        metrics: [ServiceType: UsageMetrics],
        accounts: [AccountUsageSnapshot],
        provider: String? = nil,
        account: String? = nil
    ) -> UsageCLISelection {
        let filteredMetrics = CLIProviderFilter.apply(provider, to: metrics)
        let selectedProviders = CLIProviderFilter.select(provider)
        let providerFilteredAccounts = accounts.filter { selectedProviders.contains($0.metrics.service) }
        return UsageCLISelection(
            metrics: filteredMetrics,
            accounts: CLIAccountFilter.apply(account, to: providerFilteredAccounts),
            providerFilter: provider,
            accountFilter: account
        )
    }

    /// `nil` when the selection has something to print. Distinguishes a provider
    /// typo from an account typo from a real provider the cache has not seen.
    public var emptyReportMessage: String? {
        if CLIProviderFilter.select(providerFilter).isEmpty {
            return CLIProviderFilter.noMatchesMessage
        }
        if CLIAccountFilter.isActive(accountFilter), accounts.isEmpty {
            return Self.noMatchingAccountsMessage
        }
        if metrics.isEmpty, accounts.isEmpty {
            return CLIProviderFilter.emptyReportMessage(for: providerFilter)
        }
        return nil
    }
}

/// Exact-token account matching for `--account` / `?account=`.
nonisolated enum CLIAccountFilter {
    static func isActive(_ filter: String?) -> Bool {
        needle(from: filter) != nil
    }

    static func apply(_ filter: String?, to accounts: [AccountUsageSnapshot]) -> [AccountUsageSnapshot] {
        let filtered: [AccountUsageSnapshot]
        if let needle = needle(from: filter) {
            filtered = accounts.filter { matches($0, needle) }
        } else {
            filtered = accounts
        }
        return sorted(filtered)
    }

    private static func needle(from filter: String?) -> String? {
        guard let trimmed = filter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func matches(_ snapshot: AccountUsageSnapshot, _ needle: String) -> Bool {
        snapshot.id.uuidString.compare(needle, options: .caseInsensitive) == .orderedSame
            || snapshot.name.compare(needle, options: .caseInsensitive) == .orderedSame
    }

    private static func sorted(_ accounts: [AccountUsageSnapshot]) -> [AccountUsageSnapshot] {
        accounts.sorted { lhs, rhs in
            if lhs.metrics.service.sortOrder != rhs.metrics.service.sortOrder {
                return lhs.metrics.service.sortOrder < rhs.metrics.service.sortOrder
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
