import Combine
import Foundation
import MeterBarShared

nonisolated enum StatusItemLabelMetric: String, CaseIterable, Identifiable {
    case percentLeft
    case percentUsed
    case iconOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .percentLeft: return "Percentage Left"
        case .percentUsed: return "Percentage Used"
        case .iconOnly: return "Icon Only"
        }
    }
}

/// How many status items MeterBar owns in the menu bar, and what scopes them.
nonisolated enum MenuBarPresentationMode: String, CaseIterable, Identifiable, Sendable {
    /// One status item showing a single quota (Auto or an explicit pin).
    case merged
    /// One status item per tracked provider account, CodexBar-style.
    case perProvider
    /// One status item per account the user selected, capped at
    /// `MenuBarAccountItemPlanner.maximumConcurrentItems` (issue #266).
    case perAccount
    /// One status item bound to a single account, switchable from its own
    /// right-click menu (issue #266).
    case accountSwitcher

    var id: String { rawValue }

    /// True for the modes whose items are scoped to one account, so callers can
    /// ask that question without enumerating cases at every call site.
    var isAccountScoped: Bool {
        switch self {
        case .merged, .perProvider: return false
        case .perAccount, .accountSwitcher: return true
        }
    }

    var displayName: String {
        switch self {
        case .merged: return "Single Item"
        case .perProvider: return "One Per Provider"
        case .perAccount: return "One Per Account"
        case .accountSwitcher: return "One Account With Switcher"
        }
    }
}

nonisolated enum StatusItemLabelSize: String, CaseIterable, Identifiable {
    case compact
    case regular

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

nonisolated enum ResetTimeFormat: String, CaseIterable, Identifiable {
    case countdown
    case clock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .countdown: return "Countdown"
        case .clock: return "Clock Time"
        }
    }
}

/// Persists the status-item and popover-label choices introduced by issue #142.
/// Defaults preserve the exact pre-feature presentation: Auto selection, a
/// compact percentage-left label, and reset countdowns.
final class MenuBarDisplayPreferencesStore: ObservableObject {
    static let shared = MenuBarDisplayPreferencesStore()

    @Published private(set) var pinnedCandidateKey: String?
    @Published private(set) var presentationMode: MenuBarPresentationMode
    @Published private(set) var labelMetric: StatusItemLabelMetric
    @Published private(set) var labelSize: StatusItemLabelSize
    @Published private(set) var resetTimeFormat: ResetTimeFormat

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        pinnedCandidateKey = userDefaults.string(forKey: StorageKeys.statusItemPinnedCandidate)
            .flatMap(Self.normalizedPin)
        presentationMode = userDefaults.string(forKey: StorageKeys.statusItemPresentationMode)
            .flatMap(MenuBarPresentationMode.init(rawValue:)) ?? .merged
        labelMetric = userDefaults.string(forKey: StorageKeys.statusItemLabelMetric)
            .flatMap(StatusItemLabelMetric.init(rawValue:)) ?? .percentLeft
        labelSize = userDefaults.string(forKey: StorageKeys.statusItemLabelSize)
            .flatMap(StatusItemLabelSize.init(rawValue:)) ?? .compact
        resetTimeFormat = userDefaults.string(forKey: StorageKeys.popoverResetTimeFormat)
            .flatMap(ResetTimeFormat.init(rawValue:)) ?? .countdown
    }

    func setPinnedCandidateKey(_ key: String?) {
        let normalized = key.flatMap(Self.normalizedPin)
        guard normalized != pinnedCandidateKey else { return }
        pinnedCandidateKey = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: StorageKeys.statusItemPinnedCandidate)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.statusItemPinnedCandidate)
        }
    }

    func setPresentationMode(_ mode: MenuBarPresentationMode) {
        guard mode != presentationMode else { return }
        presentationMode = mode
        userDefaults.set(mode.rawValue, forKey: StorageKeys.statusItemPresentationMode)
    }

    func setLabelMetric(_ metric: StatusItemLabelMetric) {
        guard metric != labelMetric else { return }
        labelMetric = metric
        userDefaults.set(metric.rawValue, forKey: StorageKeys.statusItemLabelMetric)
    }

    func setLabelSize(_ size: StatusItemLabelSize) {
        guard size != labelSize else { return }
        labelSize = size
        userDefaults.set(size.rawValue, forKey: StorageKeys.statusItemLabelSize)
    }

    func setResetTimeFormat(_ format: ResetTimeFormat) {
        guard format != resetTimeFormat else { return }
        resetTimeFormat = format
        userDefaults.set(format.rawValue, forKey: StorageKeys.popoverResetTimeFormat)
    }

    nonisolated private static func normalizedPin(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum StatusItemLabelFormatter {
    static func title(
        for limit: UsageLimit,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize
    ) -> String? {
        guard let value = value(for: limit, metric: metric) else { return nil }
        guard size == .regular else { return "\(value)%" }
        return "\(value)% \(metric == .percentLeft ? "left" : "used")"
    }

    static func spokenValue(for limit: UsageLimit, metric: StatusItemLabelMetric) -> String? {
        guard let value = value(for: limit, metric: metric) else { return nil }
        return "\(value)% \(metric == .percentLeft ? "left" : "used")"
    }

    private static func value(for limit: UsageLimit, metric: StatusItemLabelMetric) -> Int? {
        switch metric {
        case .percentLeft:
            return QuotaMath.percentLeft(for: limit)
        case .percentUsed:
            return Int(limit.percentage.rounded())
        case .iconOnly:
            return nil
        }
    }
}
