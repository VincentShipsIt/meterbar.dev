import Foundation

public enum WidgetDataHealth: Equatable, Sendable {
    case healthy
    case stale
    case unavailable
}

public enum WidgetPresentationEmptyState: Equatable, Sendable {
    case noSelection
    case unavailable

    public var title: String {
        switch self {
        case .noSelection:
            return "Choose usage to show"
        case .unavailable:
            return "Usage unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .noSelection:
            return "Select accounts and quota windows in MeterBar Settings."
        case .unavailable:
            return "Open MeterBar to refresh provider usage."
        }
    }
}

public struct WidgetPresentationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountIdentifier: WidgetAccountIdentifier
    public let service: ServiceType
    public let accountName: String
    public let quotaWindow: WidgetQuotaWindow
    public let limit: UsageLimit?
    public let health: WidgetDataHealth
    public let displayMode: WidgetUsageDisplayMode
    public let preservesLegacyOpenRouterBalance: Bool
    public let resetTime: Date?
    public let freshnessDate: Date?

    public var quotaTitle: String {
        switch (service, quotaWindow) {
        case (.openRouter, .session):
            return "Key limit"
        case (.openRouter, .weekly):
            return "Account credits"
        case (.claudeCode, .codeReview):
            return "Sonnet"
        case (_, .codeReview):
            return "Code Review"
        case (_, .session):
            return "Session"
        case (_, .weekly):
            return "Weekly"
        }
    }

    public var progressValue: Double? {
        guard let limit else { return nil }
        switch displayMode {
        case .used:
            return limit.clampedUsed
        case .remaining:
            return max(0, limit.total - limit.clampedUsed)
        }
    }

    public var progressTotal: Double? {
        limit?.clampedTotal
    }

    public var summaryText: String {
        guard let limit else { return "Unavailable" }
        if service == .openRouter {
            let amount: Double
            let suffix: String
            switch preservesLegacyOpenRouterBalance ? .remaining : displayMode {
            case .used:
                amount = max(0, limit.used)
                suffix = "used"
            case .remaining:
                amount = max(0, limit.total - limit.used)
                suffix = "left"
            }
            return "\(ExtraUsageStatus.formatAmount(amount)) \(suffix)"
        }

        switch displayMode {
        case .used:
            return limit.usedPercentageText
        case .remaining:
            return limit.percentLeftText
        }
    }

    public var compactSummaryText: String {
        guard service == .openRouter,
              preservesLegacyOpenRouterBalance,
              let limit else {
            return summaryText
        }
        return ExtraUsageStatus.formatAmount(max(0, limit.total - limit.used))
    }

    public var usageStatus: UsageStatus? {
        guard health == .healthy else { return nil }
        return limit?.statusColor
    }
}

public struct WidgetPresentation: Equatable, Sendable {
    public let rows: [WidgetPresentationRow]
    public let hiddenRowCount: Int
    public let emptyState: WidgetPresentationEmptyState?
}

/// Pure data-to-presentation policy shared by every widget family.
///
/// The planner reads no global state and owns no clock. Inputs are the existing
/// App Group metrics snapshots plus the persisted widget preferences, which
/// keeps ordering, staleness, quota-window filtering, and overflow deterministic
/// and directly testable.
public enum WidgetPresentationPlanner {
    public static let defaultStalenessThreshold: TimeInterval = 2 * 60 * 60

    public static func makePresentation(
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [AccountUsageSnapshot],
        preferences: WidgetPreferences,
        family: WidgetPresentationFamily,
        now: Date,
        stalenessThreshold: TimeInterval = defaultStalenessThreshold
    ) -> WidgetPresentation {
        guard preferences.accountSelection.mode != .explicit
            || !preferences.accountSelection.explicitIdentifiers.isEmpty,
            !preferences.visibleQuotaWindows.isEmpty
        else {
            return WidgetPresentation(rows: [], hiddenRowCount: 0, emptyState: .noSelection)
        }

        let sources = availableSources(metrics: metrics, accountMetrics: accountMetrics)
        let selectedSources = selectedSources(from: sources, preferences: preferences)
        let rows = selectedSources.flatMap {
            presentationRows(
                for: $0,
                preferences: preferences,
                now: now,
                stalenessThreshold: stalenessThreshold
            )
        }

        guard !rows.isEmpty else {
            return WidgetPresentation(rows: [], hiddenRowCount: 0, emptyState: .unavailable)
        }

        let budget = WidgetFamilyRowBudget.plan(
            totalRowCount: rows.count,
            family: family,
            showsDetails: rows.contains { $0.resetTime != nil || $0.freshnessDate != nil }
        )
        return WidgetPresentation(
            rows: Array(rows.prefix(budget.visibleRowCount)),
            hiddenRowCount: budget.hiddenRowCount,
            emptyState: nil
        )
    }

    private struct Source {
        let identifier: WidgetAccountIdentifier
        let service: ServiceType
        let accountOrder: Int
        let name: String
        let metrics: UsageMetrics?
    }

    private static func availableSources(
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [AccountUsageSnapshot]
    ) -> [Source] {
        var accountOrderByService: [ServiceType: Int] = [:]
        let accountSources = accountMetrics.map { snapshot -> Source in
            let service = snapshot.metrics.service
            let accountOrder = accountOrderByService[service, default: 0]
            accountOrderByService[service] = accountOrder + 1
            return Source(
                identifier: .account(service: service, id: snapshot.id),
                service: service,
                accountOrder: accountOrder,
                name: snapshot.name,
                metrics: snapshot.metrics
            )
        }

        let providerSources = metrics.map { service, providerMetrics in
            Source(
                identifier: .provider(service),
                service: service,
                accountOrder: 0,
                name: service.displayName,
                metrics: providerMetrics
            )
        }

        return accountSources + providerSources
    }

    private static func selectedSources(
        from sources: [Source],
        preferences: WidgetPreferences
    ) -> [Source] {
        let selected: [Source]
        switch preferences.accountSelection.mode {
        case .all:
            let accountServices = Set(
                sources.compactMap { source in
                    source.identifier == .provider(source.service) ? nil : source.service
                }
            )
            selected = sources.filter {
                $0.identifier != .provider($0.service) || !accountServices.contains($0.service)
            }
        case .explicit:
            let sourceByIdentifier = Dictionary(
                sources.map { ($0.identifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            selected = preferences.accountSelection.explicitIdentifiers.compactMap { identifier in
                if let source = sourceByIdentifier[identifier] {
                    return source
                }
                guard let service = identifier.service else { return nil }
                return Source(
                    identifier: identifier,
                    service: service,
                    accountOrder: Int.max,
                    name: service.displayName,
                    metrics: nil
                )
            }
        }

        return selected.sorted { lhs, rhs in
            switch preferences.accountOrdering {
            case .provider:
                return providerOrder(lhs) < providerOrder(rhs)
            case .urgency:
                let lhsUrgency = urgency(lhs, visibleWindows: preferences.visibleQuotaWindows)
                let rhsUrgency = urgency(rhs, visibleWindows: preferences.visibleQuotaWindows)
                if lhsUrgency != rhsUrgency {
                    return lhsUrgency > rhsUrgency
                }
                return providerOrder(lhs) < providerOrder(rhs)
            }
        }
    }

    private static func providerOrder(_ source: Source) -> (Int, Int, String) {
        (source.service.sortOrder, source.accountOrder, source.identifier.rawValue)
    }

    private static func urgency(
        _ source: Source,
        visibleWindows: Set<WidgetQuotaWindow>
    ) -> Double {
        guard let metrics = source.metrics else { return -Double.infinity }
        return WidgetQuotaWindow.allCases
            .filter { visibleWindows.contains($0) }
            .compactMap { limit(for: $0, metrics: metrics)?.percentage }
            .max() ?? 0
    }

    private static func presentationRows(
        for source: Source,
        preferences: WidgetPreferences,
        now: Date,
        stalenessThreshold: TimeInterval
    ) -> [WidgetPresentationRow] {
        let windows = WidgetQuotaWindow.allCases.filter {
            preferences.visibleQuotaWindows.contains($0)
        }

        guard let metrics = source.metrics else {
            guard let firstWindow = windows.first else { return [] }
            return [
                row(
                    source: source,
                    window: firstWindow,
                    limit: nil,
                    health: .unavailable,
                    preferences: preferences
                )
            ]
        }

        let health: WidgetDataHealth = now.timeIntervalSince(metrics.lastUpdated) > stalenessThreshold
            ? .stale
            : .healthy
        return windows.compactMap { window in
            guard let limit = limit(for: window, metrics: metrics) else { return nil }
            return row(
                source: source,
                window: window,
                limit: limit,
                health: health,
                preferences: preferences
            )
        }
    }

    private static func row(
        source: Source,
        window: WidgetQuotaWindow,
        limit: UsageLimit?,
        health: WidgetDataHealth,
        preferences: WidgetPreferences
    ) -> WidgetPresentationRow {
        WidgetPresentationRow(
            id: "\(source.identifier.rawValue):\(window.rawValue)",
            accountIdentifier: source.identifier,
            service: source.service,
            accountName: source.name,
            quotaWindow: window,
            limit: limit,
            health: health,
            displayMode: preferences.displayMode,
            preservesLegacyOpenRouterBalance: source.service == .openRouter
                && preferences.preservesLegacyOpenRouterBalance,
            resetTime: preferences.showsResetTime ? limit?.resetTime : nil,
            freshnessDate: preferences.showsFreshness ? source.metrics?.lastUpdated : nil
        )
    }

    private static func limit(
        for window: WidgetQuotaWindow,
        metrics: UsageMetrics
    ) -> UsageLimit? {
        switch window {
        case .session:
            return metrics.sessionLimit
        case .weekly:
            return metrics.weeklyLimit
        case .codeReview:
            return metrics.codeReviewLimit
        }
    }
}
