import Combine
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Stable identity for one provider-level or account-level widget row.
///
/// The value deliberately includes the service for account rows so a UUID can
/// never be attributed to the wrong provider after preferences are restored.
public struct WidgetAccountIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func provider(_ service: ServiceType) -> Self {
        Self(rawValue: "provider:\(service.rawValue)")
    }

    public static func account(service: ServiceType, id: UUID) -> Self {
        Self(rawValue: "account:\(service.rawValue):\(id.uuidString)")
    }

    /// Recovers the provider identity from a persisted row key.
    ///
    /// Explicit selections can outlive a metrics snapshot (for example while
    /// an enabled account is temporarily unavailable). The widget uses this
    /// provider identity to render an honest unavailable row instead of
    /// silently relabeling or dropping the selection.
    public var service: ServiceType? {
        let providerPrefix = "provider:"
        if rawValue.hasPrefix(providerPrefix) {
            return ServiceType(rawValue: String(rawValue.dropFirst(providerPrefix.count)))
        }

        let accountPrefix = "account:"
        guard rawValue.hasPrefix(accountPrefix) else { return nil }
        let accountValue = rawValue.dropFirst(accountPrefix.count)
        guard let separator = accountValue.firstIndex(of: ":") else { return nil }
        return ServiceType(rawValue: String(accountValue[..<separator]))
    }
}

public enum WidgetAccountSelectionMode: String, Codable, Sendable {
    case all
    case explicit
}

public struct WidgetAccountSelection: Codable, Equatable, Sendable {
    public let mode: WidgetAccountSelectionMode
    public let accountIdentifiers: [WidgetAccountIdentifier]

    public static let all = WidgetAccountSelection(mode: .all, accountIdentifiers: [])

    public static func explicit(_ identifiers: Set<WidgetAccountIdentifier>) -> Self {
        Self(mode: .explicit, accountIdentifiers: Array(identifiers))
    }

    public init(mode: WidgetAccountSelectionMode, accountIdentifiers: [WidgetAccountIdentifier]) {
        self.mode = mode
        self.accountIdentifiers = mode == .all
            ? []
            : Array(Set(accountIdentifiers)).sorted { $0.rawValue < $1.rawValue }
    }

    public var explicitIdentifiers: Set<WidgetAccountIdentifier> {
        Set(accountIdentifiers)
    }
}

public enum WidgetUsageDisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining
    case used
}

public enum WidgetQuotaWindow: String, Codable, CaseIterable, Sendable {
    case session
    case weekly
    case codeReview
}

public enum WidgetAccountOrdering: String, Codable, CaseIterable, Sendable {
    case provider
    case urgency
}

/// Cross-target value stored in the App Group and read by both the app and
/// widget extension. Missing fields decode to the pre-preference widget
/// behavior so future additions remain backward compatible.
public struct WidgetPreferences: Codable, Equatable, Sendable {
    public var accountSelection: WidgetAccountSelection
    public var displayMode: WidgetUsageDisplayMode
    public var visibleQuotaWindows: Set<WidgetQuotaWindow>
    public var showsResetTime: Bool
    public var showsFreshness: Bool
    public var accountOrdering: WidgetAccountOrdering
    /// Keeps the pre-preference OpenRouter balance (`remaining`) until the
    /// user explicitly chooses either usage display mode.
    public var preservesLegacyOpenRouterBalance: Bool

    public static let defaults = WidgetPreferences(
        accountSelection: .all,
        displayMode: .used,
        visibleQuotaWindows: [.weekly],
        showsResetTime: false,
        showsFreshness: false,
        accountOrdering: .provider,
        preservesLegacyOpenRouterBalance: true
    )

    public init(
        accountSelection: WidgetAccountSelection,
        displayMode: WidgetUsageDisplayMode,
        visibleQuotaWindows: Set<WidgetQuotaWindow>,
        showsResetTime: Bool,
        showsFreshness: Bool,
        accountOrdering: WidgetAccountOrdering,
        preservesLegacyOpenRouterBalance: Bool = true
    ) {
        self.accountSelection = accountSelection
        self.displayMode = displayMode
        self.visibleQuotaWindows = visibleQuotaWindows
        self.showsResetTime = showsResetTime
        self.showsFreshness = showsFreshness
        self.accountOrdering = accountOrdering
        self.preservesLegacyOpenRouterBalance = preservesLegacyOpenRouterBalance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountSelection = try container.decodeIfPresent(
            WidgetAccountSelection.self,
            forKey: .accountSelection
        ) ?? Self.defaults.accountSelection
        displayMode = try container.decodeIfPresent(
            WidgetUsageDisplayMode.self,
            forKey: .displayMode
        ) ?? Self.defaults.displayMode
        visibleQuotaWindows = try container.decodeIfPresent(
            Set<WidgetQuotaWindow>.self,
            forKey: .visibleQuotaWindows
        ) ?? Self.defaults.visibleQuotaWindows
        showsResetTime = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsResetTime
        ) ?? Self.defaults.showsResetTime
        showsFreshness = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsFreshness
        ) ?? Self.defaults.showsFreshness
        accountOrdering = try container.decodeIfPresent(
            WidgetAccountOrdering.self,
            forKey: .accountOrdering
        ) ?? Self.defaults.accountOrdering
        preservesLegacyOpenRouterBalance = try container.decodeIfPresent(
            Bool.self,
            forKey: .preservesLegacyOpenRouterBalance
        ) ?? Self.defaults.preservesLegacyOpenRouterBalance
    }
}

/// Pure input to widget account filtering. The app can describe configured
/// accounts even when metrics are missing; the selector safely removes
/// disabled and unavailable rows without erasing the persisted selection.
public struct WidgetAccountCandidate: Equatable, Sendable {
    public let identifier: WidgetAccountIdentifier
    public let service: ServiceType
    public let accountOrder: Int
    public let isProviderEnabled: Bool
    public let isAccountEnabled: Bool
    public let isAvailable: Bool
    public let urgency: Double

    public init(
        identifier: WidgetAccountIdentifier,
        service: ServiceType,
        accountOrder: Int,
        isProviderEnabled: Bool = true,
        isAccountEnabled: Bool = true,
        isAvailable: Bool = true,
        urgency: Double = 0
    ) {
        self.identifier = identifier
        self.service = service
        self.accountOrder = accountOrder
        self.isProviderEnabled = isProviderEnabled
        self.isAccountEnabled = isAccountEnabled
        self.isAvailable = isAvailable
        self.urgency = urgency
    }
}

public enum WidgetAccountSelector {
    public static func select(
        from candidates: [WidgetAccountCandidate],
        using preferences: WidgetPreferences
    ) -> [WidgetAccountCandidate] {
        let explicitIdentifiers = preferences.accountSelection.explicitIdentifiers
        let selected = candidates.filter { candidate in
            guard candidate.isProviderEnabled,
                  candidate.isAccountEnabled,
                  candidate.isAvailable else {
                return false
            }

            switch preferences.accountSelection.mode {
            case .all:
                return true
            case .explicit:
                return explicitIdentifiers.contains(candidate.identifier)
            }
        }

        return selected.sorted { lhs, rhs in
            switch preferences.accountOrdering {
            case .provider:
                return providerOrder(lhs) < providerOrder(rhs)
            case .urgency:
                if normalizedUrgency(lhs.urgency) != normalizedUrgency(rhs.urgency) {
                    return normalizedUrgency(lhs.urgency) > normalizedUrgency(rhs.urgency)
                }
                return providerOrder(lhs) < providerOrder(rhs)
            }
        }
    }

    private static func providerOrder(_ candidate: WidgetAccountCandidate) -> (Int, Int, String) {
        (candidate.service.sortOrder, candidate.accountOrder, candidate.identifier.rawValue)
    }

    private static func normalizedUrgency(_ urgency: Double) -> Double {
        urgency.isFinite ? urgency : 0
    }
}

/// App Group-backed preference store. Mutations persist one shared Codable
/// value and request exactly one widget timeline reload through an injectable
/// seam.
public final class WidgetPreferencesStore: ObservableObject {
    public static let shared = WidgetPreferencesStore()

    @Published public private(set) var preferences: WidgetPreferences

    private static let storageKey = "WidgetPreferences"

    private let userDefaults: UserDefaults
    private let reloadTimelines: () -> Void

    public convenience init() {
        self.init(
            userDefaults: UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) ?? .standard,
            reloadTimelines: Self.reloadWidgetTimelines
        )
    }

    public init(userDefaults: UserDefaults, reloadTimelines: @escaping () -> Void) {
        self.userDefaults = userDefaults
        self.reloadTimelines = reloadTimelines

        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(WidgetPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .defaults
        }
    }

    public func selectAllAccounts() {
        update { $0.accountSelection = .all }
    }

    public func setSelectedAccounts(_ identifiers: Set<WidgetAccountIdentifier>) {
        update { $0.accountSelection = .explicit(identifiers) }
    }

    public func setDisplayMode(_ displayMode: WidgetUsageDisplayMode) {
        update {
            $0.displayMode = displayMode
            $0.preservesLegacyOpenRouterBalance = false
        }
    }

    public func setVisibleQuotaWindows(_ windows: Set<WidgetQuotaWindow>) {
        update { $0.visibleQuotaWindows = windows }
    }

    public func setShowsResetTime(_ showsResetTime: Bool) {
        update { $0.showsResetTime = showsResetTime }
    }

    public func setShowsFreshness(_ showsFreshness: Bool) {
        update { $0.showsFreshness = showsFreshness }
    }

    public func setAccountOrdering(_ accountOrdering: WidgetAccountOrdering) {
        update { $0.accountOrdering = accountOrdering }
    }

    private func update(_ mutation: (inout WidgetPreferences) -> Void) {
        var nextPreferences = preferences
        mutation(&nextPreferences)
        guard nextPreferences != preferences else { return }

        preferences = nextPreferences
        if let data = try? JSONEncoder().encode(nextPreferences) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
        reloadTimelines()
    }

    private static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "UsageWidget")
        #endif
    }
}
