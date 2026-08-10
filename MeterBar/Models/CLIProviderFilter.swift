import Foundation
import MeterBarShared

/// The `--provider` substring filter shared by `meterbar usage` and
/// `meterbar doctor`.
///
/// Both commands matched providers with their own copy of the same expression,
/// and only `doctor` said anything when the filter matched nothing. Sharing the
/// selection — and the message — keeps a typo from reading like "this provider
/// has no quota data".
nonisolated public enum CLIProviderFilter {
    /// Printed by both commands when `--provider` excludes everything.
    public static let noMatchesMessage = "No matching providers."

    /// Explains an empty report. A filter that names no provider at all is a
    /// typo; one that names a real provider only means the cache holds nothing
    /// for it yet, and answering that with "no matching providers" would read
    /// like the provider does not exist.
    public static func emptyReportMessage(for filter: String?) -> String {
        let selected = select(filter)
        guard !selected.isEmpty else { return noMatchesMessage }

        let names = selected.map(\.displayName).sorted().joined(separator: ", ")
        return "No cached usage for \(names). Run `meterbar refresh` first."
    }

    /// Providers whose identifier or display name contains `filter`. A missing
    /// or blank filter selects every provider; a filter that matches nothing
    /// selects nothing.
    public static func select(_ filter: String?) -> Set<ServiceType> {
        guard let needle = needle(from: filter) else { return Set(ServiceType.allCases) }
        return Set(ServiceType.allCases.filter { matches($0, needle) })
    }

    /// The same selection applied to a cached metrics snapshot.
    public static func apply(
        _ filter: String?,
        to metrics: [ServiceType: UsageMetrics]
    ) -> [ServiceType: UsageMetrics] {
        guard let needle = needle(from: filter) else { return metrics }
        return metrics.filter { matches($0.key, needle) }
    }

    private static func needle(from filter: String?) -> String? {
        guard let trimmed = filter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func matches(_ service: ServiceType, _ needle: String) -> Bool {
        service.rawValue.lowercased().contains(needle)
            || service.displayName.lowercased().contains(needle)
    }
}
