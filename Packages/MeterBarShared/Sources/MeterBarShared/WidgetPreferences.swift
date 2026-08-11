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

    /// Keeps the stored identifiers when the mode is a case this build does not
    /// know.
    ///
    /// A newer app version writing a future selection mode into the shared App
    /// Group must not cost the user the accounts they picked, so an unreadable
    /// mode degrades to `.explicit` whenever identifiers survived — and to
    /// `.all` only when there was nothing to keep, which is what `.all` already
    /// means.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifiers = (container.decodeTolerantly(
            [FailableBox<WidgetAccountIdentifier>].self,
            forKey: .accountIdentifiers
        ) ?? []).compactMap(\.value)
        let mode = container.decodeCaseTolerantly(
            WidgetAccountSelectionMode.self,
            forKey: .mode
        ) ?? (identifiers.isEmpty ? .all : .explicit)

        self.init(mode: mode, accountIdentifiers: identifiers)
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

    /// Decodes field by field so an unreadable one degrades alone.
    ///
    /// Tolerating only *missing* keys was enough while the app and the widget
    /// extension always shipped together, but they read this value out of the
    /// same App Group across versions. A key that is present carrying an enum
    /// case this build does not know used to throw, the store's `try?` then
    /// fell back to `.defaults`, and the next `update(_:)` wrote that fallback
    /// over the user's real settings. So every field is read independently: a
    /// value this build cannot recognize costs that field its default and
    /// nothing else, and unknown quota windows are simply not shown.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountSelection = container.decodeTolerantly(
            WidgetAccountSelection.self,
            forKey: .accountSelection
        ) ?? Self.defaults.accountSelection
        displayMode = container.decodeCaseTolerantly(
            WidgetUsageDisplayMode.self,
            forKey: .displayMode
        ) ?? Self.defaults.displayMode
        let rawWindows = container.decodeTolerantly([String].self, forKey: .visibleQuotaWindows)
        visibleQuotaWindows = rawWindows
            .map { Set($0.compactMap(WidgetQuotaWindow.init(rawValue:))) }
            ?? Self.defaults.visibleQuotaWindows
        showsResetTime = container.decodeTolerantly(
            Bool.self,
            forKey: .showsResetTime
        ) ?? Self.defaults.showsResetTime
        showsFreshness = container.decodeTolerantly(
            Bool.self,
            forKey: .showsFreshness
        ) ?? Self.defaults.showsFreshness
        accountOrdering = container.decodeCaseTolerantly(
            WidgetAccountOrdering.self,
            forKey: .accountOrdering
        ) ?? Self.defaults.accountOrdering
        preservesLegacyOpenRouterBalance = container.decodeTolerantly(
            Bool.self,
            forKey: .preservesLegacyOpenRouterBalance
        ) ?? Self.defaults.preservesLegacyOpenRouterBalance
    }
}

private extension KeyedDecodingContainer {
    /// Decodes a value, treating one this build cannot read as absent so the
    /// caller can substitute its own default.
    func decodeTolerantly<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        guard let value = try? decodeIfPresent(T.self, forKey: key) else { return nil }
        return value
    }

    /// Decodes an enum through its raw value so a case written by a different
    /// app version degrades to `nil` instead of failing the whole payload.
    func decodeCaseTolerantly<T: RawRepresentable>(
        _ type: T.Type,
        forKey key: Key
    ) -> T? where T.RawValue: Decodable {
        decodeTolerantly(T.RawValue.self, forKey: key).flatMap(T.init(rawValue:))
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

    /// Internal rather than private so a test can plant a payload written by a
    /// different app version at the exact key the store reads.
    static let storageKey = "WidgetPreferences"

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

    /// Prunes explicit selections when an account is disabled or deleted.
    /// `.all` remains dynamic by design and therefore needs no stored rewrite.
    public func reconcileAvailableAccounts(_ availableIdentifiers: Set<WidgetAccountIdentifier>) {
        guard preferences.accountSelection.mode == .explicit else { return }
        let reconciled = preferences.accountSelection.explicitIdentifiers.intersection(availableIdentifiers)
        guard reconciled != preferences.accountSelection.explicitIdentifiers else { return }
        setSelectedAccounts(reconciled)
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
        for kind in MeterBarWidgetKind.all {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        #endif
    }
}
