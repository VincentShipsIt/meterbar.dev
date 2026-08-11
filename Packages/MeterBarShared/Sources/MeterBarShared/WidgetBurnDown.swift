import Foundation

public enum WidgetBurnDownStage: Equatable, Sendable {
    case onPace
    case reserve
    case deficit
    case unavailable
}

public enum WidgetBurnDownCountdownKind: Equatable, Sendable {
    case projectedExhaustion
    case reset
    case unavailable
}

/// One selected quota window reduced to the information a countdown surface
/// needs. The underlying glance row remains the source of provider/account
/// identity, selection, quota-window naming, and data health.
public struct WidgetBurnDownRow: Identifiable, Equatable, Sendable {
    public let row: WidgetPresentationRow
    public let stage: WidgetBurnDownStage
    public let stageText: String
    public let countdownKind: WidgetBurnDownCountdownKind
    public let countdownTitle: String
    public let countdownTarget: Date?
    public let countdownText: String

    public var id: String { row.id }
    public var accountIdentifier: WidgetAccountIdentifier { row.accountIdentifier }
    public var service: ServiceType { row.service }
    public var accountName: String { row.accountName }
    public var quotaWindow: WidgetQuotaWindow { row.quotaWindow }
    public var quotaTitle: String { row.quotaTitle }
    public var health: WidgetDataHealth { row.health }
    public var isExhausted: Bool { row.limit?.isAtLimit == true }

    public var accessibilityValueText: String {
        var phrases = [quotaTitle, stageText, "\(countdownTitle) \(countdownText)"]
        if let health = health.accessibilityDescription,
           !phrases.contains(health) {
            phrases.append(health)
        }
        return phrases.joined(separator: ", ")
    }

    public init(
        row: WidgetPresentationRow,
        stage: WidgetBurnDownStage,
        stageText: String,
        countdownKind: WidgetBurnDownCountdownKind,
        countdownTitle: String,
        countdownTarget: Date?,
        countdownText: String
    ) {
        self.row = row
        self.stage = stage
        self.stageText = stageText
        self.countdownKind = countdownKind
        self.countdownTitle = countdownTitle
        self.countdownTarget = countdownTarget
        self.countdownText = countdownText
    }
}

public struct WidgetBurnDownPresentation: Equatable, Sendable {
    public let rows: [WidgetBurnDownRow]
    public let hiddenRowCount: Int
    public let emptyState: WidgetPresentationEmptyState?

    public init(
        rows: [WidgetBurnDownRow],
        hiddenRowCount: Int,
        emptyState: WidgetPresentationEmptyState?
    ) {
        self.rows = rows
        self.hiddenRowCount = hiddenRowCount
        self.emptyState = emptyState
    }
}

/// Pure burn-down policy layered on the existing widget selection planner.
///
/// Estimated and stale snapshots can still provide a provider-authored reset,
/// but never a fresh-looking projected exhaustion derived from an unreliable
/// burn rate.
public enum WidgetBurnDownPlanner {
    public static func makePresentation(
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [AccountUsageSnapshot],
        preferences: WidgetPreferences,
        family: WidgetPresentationFamily,
        now: Date,
        stalenessThreshold: TimeInterval = WidgetPresentationPlanner.defaultStalenessThreshold
    ) -> WidgetBurnDownPresentation {
        var selectionPreferences = preferences
        selectionPreferences.showsResetTime = true
        selectionPreferences.showsFreshness = false

        let base = WidgetPresentationPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: accountMetrics,
            preferences: selectionPreferences,
            family: family,
            now: now,
            stalenessThreshold: stalenessThreshold
        )
        let capacity = family == .small ? 1 : 2
        let visibleRows = Array(base.rows.prefix(capacity))

        return WidgetBurnDownPresentation(
            rows: visibleRows.map { makeRow(from: $0, now: now) },
            hiddenRowCount: base.hiddenRowCount + max(0, base.rows.count - visibleRows.count),
            emptyState: base.emptyState
        )
    }

    private static func makeRow(from row: WidgetPresentationRow, now: Date) -> WidgetBurnDownRow {
        guard row.health != .unavailable, let limit = row.limit else {
            return WidgetBurnDownRow(
                row: row,
                stage: .unavailable,
                stageText: "Usage unavailable",
                countdownKind: .unavailable,
                countdownTitle: "Countdown",
                countdownTarget: nil,
                countdownText: "Unavailable"
            )
        }

        let pace = row.health == .healthy && !limit.isEstimated
            ? limit.pace(now: now)
            : nil
        let stage = burnDownStage(pace: pace)
        let stageText: String
        if row.health == .stale {
            stageText = "Stale data"
        } else {
            stageText = pace?.leftLabel ?? "Pace unavailable"
        }

        let countdown = countdown(limit: limit, pace: pace, now: now)
        return WidgetBurnDownRow(
            row: row,
            stage: row.health == .healthy ? stage : .unavailable,
            stageText: stageText,
            countdownKind: countdown.kind,
            countdownTitle: countdown.title,
            countdownTarget: countdown.target,
            countdownText: countdown.text
        )
    }

    private static func burnDownStage(pace: UsagePace?) -> WidgetBurnDownStage {
        guard let pace else { return .unavailable }
        switch pace.stage {
        case .onPace:
            return .onPace
        case .reserve:
            return .reserve
        case .deficit:
            return .deficit
        }
    }

    private static func countdown(
        limit: UsageLimit,
        pace: UsagePace?,
        now: Date
    ) -> (kind: WidgetBurnDownCountdownKind, title: String, target: Date?, text: String) {
        if let pace,
           !pace.isExhausted,
           !pace.willLastToReset,
           let etaSeconds = pace.etaSeconds {
            let target = now.addingTimeInterval(max(0, etaSeconds))
            return (
                .projectedExhaustion,
                "Projected empty in",
                target,
                UsageDurationText.short(seconds: etaSeconds)
            )
        }

        if let resetTime = limit.resetTime {
            return (
                .reset,
                "Resets in",
                resetTime,
                limit.resetCountdownText(now: now) ?? "Unavailable"
            )
        }

        return (.unavailable, "Countdown", nil, "Unavailable")
    }
}

/// WidgetKit reload policy for countdowns. The text can animate between entries,
/// while the shared pace calculation is recomputed at least every 15 minutes
/// and at an earlier reset/exhaustion boundary when one is close.
public enum WidgetBurnDownTimeline {
    public static let minimumRefreshInterval: TimeInterval = 60
    public static let maximumRefreshInterval: TimeInterval = 15 * 60

    public static func nextUpdateDate(
        after now: Date,
        presentation: WidgetBurnDownPresentation
    ) -> Date {
        let maximumRefresh = now.addingTimeInterval(maximumRefreshInterval)
        let nearestBoundary = presentation.rows
            .compactMap(\.countdownTarget)
            .filter { $0 > now }
            .min() ?? maximumRefresh
        let requested = min(maximumRefresh, nearestBoundary)
        return max(now.addingTimeInterval(minimumRefreshInterval), requested)
    }
}
