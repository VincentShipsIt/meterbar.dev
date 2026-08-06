import Combine
import Foundation
import MeterBarShared

nonisolated enum StatusItemLabelMetric: String, CaseIterable, Identifiable {
    case percentLeft
    case percentUsed
    case pace
    case iconOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .percentLeft: return "Percentage Left"
        case .percentUsed: return "Percentage Used"
        case .pace: return "Pace (Reserve / Deficit)"
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

/// Which quota windows share one status-item label. This is deliberately
/// separate from `MenuBarPresentationMode`, which controls how many items the
/// app owns. The default is the single selected window used before issue #269.
nonisolated enum StatusItemWindowMode: String, CaseIterable, Identifiable {
    case selected
    case combined

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selected: return "Selected"
        case .combined: return "Session + Weekly"
        }
    }
}

/// User-controlled point size for the AppKit status-item label. `.standard`
/// deliberately has no numeric override, leaving AppKit's native menu-bar
/// typography untouched for existing installs.
nonisolated enum StatusItemFontSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        }
    }

    var pointSize: Double? {
        switch self {
        case .small: return 11
        case .standard: return nil
        case .large: return 15
        }
    }
}

nonisolated struct StatusItemVisualStyle: Equatable, Sendable {
    let fontSize: StatusItemFontSize
    let highContrast: Bool
}

/// Pure light/dark contract for the AppKit presenter. Standard mode leaves
/// tinting to macOS. High contrast uses the strongest adaptive foreground so
/// both the template icon and attributed title remain legible over tinting.
nonisolated enum StatusItemContrastPalette {
    enum Appearance {
        case light
        case dark
    }

    enum Tone: Equatable {
        case automatic
        case black
        case white
    }

    static func tone(highContrast: Bool, appearance: Appearance) -> Tone {
        guard highContrast else { return .automatic }
        return appearance == .dark ? .white : .black
    }
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
    @Published private(set) var windowMode: StatusItemWindowMode
    @Published private(set) var fontSize: StatusItemFontSize
    @Published private(set) var highContrast: Bool
    @Published private(set) var showsExhaustedResetCountdown: Bool
    @Published private(set) var resetTimeFormat: ResetTimeFormat
    @Published private(set) var showsRecommendationHint: Bool

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
        windowMode = userDefaults.string(forKey: StorageKeys.statusItemWindowMode)
            .flatMap(StatusItemWindowMode.init(rawValue:)) ?? .selected
        fontSize = userDefaults.string(forKey: StorageKeys.statusItemFontSize)
            .flatMap(StatusItemFontSize.init(rawValue:)) ?? .standard
        highContrast = userDefaults.bool(forKey: StorageKeys.statusItemHighContrast)
        showsExhaustedResetCountdown = userDefaults.bool(
            forKey: StorageKeys.statusItemShowsExhaustedResetCountdown
        )
        resetTimeFormat = userDefaults.string(forKey: StorageKeys.popoverResetTimeFormat)
            .flatMap(ResetTimeFormat.init(rawValue:)) ?? .countdown
        // Off unless asked for: the popover's layout stays exactly as it was
        // before the recommendation shipped.
        showsRecommendationHint = userDefaults.bool(forKey: StorageKeys.popoverShowsRecommendationHint)
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

    func setWindowMode(_ mode: StatusItemWindowMode) {
        guard mode != windowMode else { return }
        windowMode = mode
        userDefaults.set(mode.rawValue, forKey: StorageKeys.statusItemWindowMode)
    }

    func setFontSize(_ size: StatusItemFontSize) {
        guard size != fontSize else { return }
        fontSize = size
        userDefaults.set(size.rawValue, forKey: StorageKeys.statusItemFontSize)
    }

    func setHighContrast(_ enabled: Bool) {
        guard enabled != highContrast else { return }
        highContrast = enabled
        userDefaults.set(enabled, forKey: StorageKeys.statusItemHighContrast)
    }

    func setShowsExhaustedResetCountdown(_ enabled: Bool) {
        guard enabled != showsExhaustedResetCountdown else { return }
        showsExhaustedResetCountdown = enabled
        userDefaults.set(enabled, forKey: StorageKeys.statusItemShowsExhaustedResetCountdown)
    }

    func setResetTimeFormat(_ format: ResetTimeFormat) {
        guard format != resetTimeFormat else { return }
        resetTimeFormat = format
        userDefaults.set(format.rawValue, forKey: StorageKeys.popoverResetTimeFormat)
    }

    func setShowsRecommendationHint(_ enabled: Bool) {
        guard enabled != showsRecommendationHint else { return }
        showsRecommendationHint = enabled
        userDefaults.set(enabled, forKey: StorageKeys.popoverShowsRecommendationHint)
    }

    nonisolated private static func normalizedPin(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum StatusItemDataState: Equatable {
    case fresh
    case stale
    case unavailable
}

nonisolated struct StatusItemFormattedValue: Equatable {
    let visible: String?
    let spoken: String?
}

nonisolated enum StatusItemLabelFormatter {
    /// Includes the leading window qualifiers but excludes the single leading
    /// status-item spacer. Every numeric token is capped, so this remains a
    /// real width contract rather than a best-effort `lineLimit`.
    static let maximumCombinedTitleCharacters = 32

    static func title(
        for limit: UsageLimit,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        now: Date = Date()
    ) -> String? {
        formatted(
            limit: limit,
            metric: metric,
            size: size,
            state: .fresh,
            showsExhaustedResetCountdown: false,
            now: now
        ).visible
    }

    static func spokenValue(
        for limit: UsageLimit,
        metric: StatusItemLabelMetric,
        now: Date = Date()
    ) -> String? {
        formatted(
            limit: limit,
            metric: metric,
            size: .regular,
            state: .fresh,
            showsExhaustedResetCountdown: false,
            now: now
        ).spoken
    }

    static func formatted(
        limit: UsageLimit?,
        metric: StatusItemLabelMetric,
        size: StatusItemLabelSize,
        state: StatusItemDataState,
        showsExhaustedResetCountdown: Bool,
        now: Date
    ) -> StatusItemFormattedValue {
        guard metric != .iconOnly else {
            return StatusItemFormattedValue(visible: nil, spoken: nil)
        }

        switch state {
        case .stale:
            return StatusItemFormattedValue(visible: "—", spoken: "data stale")
        case .unavailable:
            return StatusItemFormattedValue(visible: "—", spoken: unavailableSpokenValue(for: metric))
        case .fresh:
            break
        }

        guard let limit else {
            return StatusItemFormattedValue(visible: "—", spoken: unavailableSpokenValue(for: metric))
        }

        if showsExhaustedResetCountdown, limit.isAtLimit {
            return resetValue(for: limit, size: size, now: now)
        }

        switch metric {
        case .percentLeft:
            let value = QuotaMath.percentLeft(for: limit)
            return StatusItemFormattedValue(
                visible: size == .compact ? "\(value)%" : "\(value)% left",
                spoken: "\(value)% left"
            )
        case .percentUsed:
            let value = Int(limit.percentage.rounded())
            return StatusItemFormattedValue(
                visible: size == .compact ? "\(value)%" : "\(value)% used",
                spoken: "\(value)% used"
            )
        case .pace:
            return paceValue(for: limit, size: size, now: now)
        case .iconOnly:
            return StatusItemFormattedValue(visible: nil, spoken: nil)
        }
    }

    static func combinedToken(
        prefix: String,
        value: StatusItemFormattedValue,
        size: StatusItemLabelSize
    ) -> String {
        let visible = value.visible ?? "—"
        return size == .compact ? "\(prefix)\(visible)" : "\(prefix) \(visible)"
    }

    private static func unavailableSpokenValue(for metric: StatusItemLabelMetric) -> String {
        metric == .pace ? "pace unavailable" : "usage unavailable"
    }

    private static func paceValue(
        for limit: UsageLimit,
        size: StatusItemLabelSize,
        now: Date
    ) -> StatusItemFormattedValue {
        guard !limit.isEstimated, let pace = limit.pace(now: now) else {
            return StatusItemFormattedValue(visible: "—", spoken: "pace unavailable")
        }

        if pace.isExhausted {
            return StatusItemFormattedValue(
                visible: size == .compact ? "Out" : "out of quota",
                spoken: "out of quota"
            )
        }

        let points = boundedPoints(abs(pace.deltaPercent))
        switch pace.stage {
        case .onPace:
            return StatusItemFormattedValue(
                visible: size == .compact ? "Pace" : "on pace",
                spoken: "On pace"
            )
        case .reserve:
            return StatusItemFormattedValue(
                visible: size == .compact ? "R\(points)%" : "\(points)% reserve",
                spoken: "\(points)% in reserve"
            )
        case .deficit:
            return StatusItemFormattedValue(
                visible: size == .compact ? "D\(points)%" : "\(points)% deficit",
                spoken: "\(points)% in deficit"
            )
        }
    }

    private static func resetValue(
        for limit: UsageLimit,
        size: StatusItemLabelSize,
        now: Date
    ) -> StatusItemFormattedValue {
        guard let seconds = limit.secondsUntilReset(now: now) else {
            return StatusItemFormattedValue(visible: "—", spoken: "reset time unavailable")
        }
        guard seconds > 0 else {
            return StatusItemFormattedValue(visible: "now", spoken: "reset due now")
        }

        let spokenDuration = UsageDurationText.short(seconds: seconds)
        let visibleDuration = boundedDuration(seconds: seconds, compact: size == .compact)
        return StatusItemFormattedValue(
            visible: size == .compact ? visibleDuration : "reset \(visibleDuration)",
            spoken: "resets in \(spokenDuration)"
        )
    }

    private static func boundedPoints(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 99 ? "99+" : "\(rounded)"
    }

    private static func boundedDuration(seconds: TimeInterval, compact: Bool) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        let days = wholeSeconds / 86_400
        let hours = (wholeSeconds % 86_400) / 3_600
        let minutes = (wholeSeconds % 3_600) / 60

        if days > 99 {
            return "99d+"
        }
        if days > 0 {
            guard !compact, hours > 0 else { return "\(days)d" }
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            guard minutes > 0 else { return "\(hours)h" }
            return compact ? "\(hours)h\(minutes)m" : "\(hours)h \(minutes)m"
        }
        if wholeSeconds < 60 {
            return "<1m"
        }
        return "\(minutes)m"
    }
}
