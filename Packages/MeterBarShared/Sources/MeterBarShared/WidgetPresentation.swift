import Foundation

public enum WidgetDataHealth: Equatable, Sendable {
    case healthy
    case stale
    case unavailable

    /// What the health glyph says out loud, or `nil` when there is no glyph.
    ///
    /// `WidgetHealthIndicator` labels its images from here so the spoken row
    /// value and the drawn badge cannot describe the same row differently. A
    /// healthy row draws nothing — its status is already the bar's tint — so it
    /// contributes no phrase.
    public var accessibilityDescription: String? {
        switch self {
        case .healthy:
            return nil
        case .stale:
            return "Stale usage data"
        case .unavailable:
            return "Usage unavailable"
        }
    }
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
    public let modelLimitLabel: String?
    public let limit: UsageLimit?
    public let health: WidgetDataHealth
    public let displayMode: WidgetUsageDisplayMode
    public let preservesLegacyOpenRouterBalance: Bool
    public let resetTime: Date?
    public let freshnessDate: Date?
    public let isBlocked: Bool
    /// Extra periods use `additionalQuotaTitleKey` so a Cursor weekly
    /// percent-pool bar titles as Grok Bot, not Other Models.
    public let isAdditionalLimit: Bool

    /// The widget marks this account row OUT while the represented quota is
    /// exhausted.
    ///
    /// This is deliberately separate from freshness: a stale snapshot can
    /// still say that the last known state was blocked, while its health badge
    /// explains that the snapshot needs refreshing.
    /// Which quota title this row resolves to, before any language is chosen.
    ///
    /// The widget extension localizes *this*, rather than re-deriving the same
    /// `(service, quotaWindow, limit)` routing against its own catalog — so a
    /// change here reaches the localized widget instead of silently diverging
    /// from it.
    public var quotaTitleKey: ServiceType.QuotaTitleKey {
        if isAdditionalLimit, let limit {
            return service.additionalQuotaTitleKey(for: limit)
        }
        if let periodKind = limit?.periodKind {
            switch periodKind {
            case .daily:
                return .daily
            case .monthly:
                return .monthly
            case .billing:
                return .billingCycle
            case .unknown:
                return .quota
            case .session:
                return service.sessionQuotaTitleKey(limitTotal: limit?.total)
            case .weekly:
                return service.weeklyQuotaTitleKey(limitTotal: limit?.total)
            }
        }
        switch quotaWindow {
        case .codeReview:
            return service.codeReviewQuotaTitleKey(modelLimitLabel: modelLimitLabel)
        case .session:
            return service.sessionQuotaTitleKey(limitTotal: limit?.total)
        case .weekly:
            return service.weeklyQuotaTitleKey(limitTotal: limit?.total)
        }
    }

    public var quotaTitle: String {
        quotaTitleKey.englishTitle
    }

    /// The quota title to use as this row's identity when compact UI cannot
    /// show both the parent account and the independently blocked sub-pool.
    ///
    /// A normal additional row still belongs to its account. An exhausted
    /// independent row does not: saying "Cursor, OUT" would imply Cursor's
    /// healthy primary pools are blocked when only Grok Bot is exhausted.
    /// Returning a localization key keeps the policy shared without choosing
    /// the widget extension's or Settings app's resource bundle here.
    public var compactIdentityQuotaTitleKey: ServiceType.QuotaTitleKey? {
        guard isBlocked, isAdditionalLimit else { return nil }
        return quotaTitleKey
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
        guard !isBlocked else { return "OUT" }
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
        guard !isBlocked else { return "OUT" }
        guard service == .openRouter,
              preservesLegacyOpenRouterBalance,
              let limit else {
            return summaryText
        }
        return ExtraUsageStatus.formatAmount(max(0, limit.total - limit.used))
    }

    public var usageStatus: UsageStatus? {
        if isBlocked { return .critical }
        guard health == .healthy else { return nil }
        return limit?.statusColor
    }

    /// The spoken value for a full glance row or hero.
    ///
    /// Those views combine their children into one accessibility element and
    /// then set this explicitly, which discards the labels `.combine` gathered
    /// from the children — including the health glyph's. Appending the health
    /// phrase here is what puts "Stale usage data" back into VoiceOver's
    /// reading of a row that visibly carries the badge.
    public var accessibilityValueText: String {
        joinedAccessibilityValue(leading: [quotaTitle, accessibilitySummaryText])
    }

    /// The spoken value for a rail entry, which omits the quota title to stay
    /// on one line — and omits the health glyph too, making this the only place
    /// a stale or unavailable rail row can announce itself at all.
    public var compactAccessibilityValueText: String {
        joinedAccessibilityValue(leading: [accessibilitySummaryText])
    }

    private var accessibilitySummaryText: String {
        isBlocked ? "Quota exhausted" : summaryText
    }

    private func joinedAccessibilityValue(leading: [String]) -> String {
        (leading + [health.accessibilityDescription].compactMap { $0 })
            .joined(separator: ", ")
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

    /// A quota row before widget-window preferences are applied. Exhausted
    /// candidates are considered across all of these rows so a weekly-only
    /// widget cannot hide a session blocker.
    private struct LimitCandidate {
        let idSuffix: String
        let window: WidgetQuotaWindow
        let limit: UsageLimit
        let isAdditional: Bool
        let blockingRole: ProviderBlockingCandidate.Role

        var blockingCandidate: ProviderBlockingCandidate {
            ProviderBlockingCandidate(id: idSuffix, role: blockingRole, limit: limit)
        }
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
        let evaluation = blockingEvaluation(in: metrics)
        if !evaluation.providerBlockers.isEmpty || !evaluation.independentSubPoolBlockers.isEmpty {
            return 100
        }
        let primary = WidgetQuotaWindow.allCases
            .filter { visibleWindows.contains($0) }
            .compactMap { limit(for: $0, metrics: metrics)?.percentage }
        let additional = metrics.additionalLimits.compactMap { additionalLimit -> Double? in
            let window = widgetWindow(for: additionalLimit.periodKind)
            guard visibleWindows.contains(window) else { return nil }
            return additionalLimit.percentage
        }
        return (primary + additional).max() ?? 0
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
        let evaluation = blockingEvaluation(in: metrics)
        let blockers = evaluation.providerBlockers + evaluation.independentSubPoolBlockers
        let blockedIDs = Set(blockers.map(\.id))
        let selectedRows: [WidgetPresentationRow] = windows.compactMap { window in
            guard let windowLimit = limit(for: window, metrics: metrics) else { return nil }
            let isBlocked = blockedIDs.contains(window.rawValue)
            return row(
                source: source,
                window: window,
                limit: windowLimit,
                health: health,
                preferences: preferences,
                isBlocked: isBlocked,
                resetTimeOverride: isBlocked ? visibleResetTime(for: windowLimit, now: now) : nil,
                usesResetTimeOverride: isBlocked
            )
        }
        let additionalRows = additionalRows(
            source: source,
            metrics: metrics,
            health: health,
            preferences: preferences,
            blockedIDs: blockedIDs,
            now: now
        )
        var rows = selectedRows + additionalRows
        guard let headline = ProviderBlockingPolicy.headline(from: blockers, now: now),
              let blocker = limitCandidates(in: metrics).first(where: {
                  $0.idSuffix == headline.blocker.id
              }) else {
            return rows
        }

        let blockedRow = row(
            source: source,
            idSuffix: blocker.idSuffix,
            window: blocker.window,
            limit: blocker.limit,
            health: health,
            preferences: preferences,
            isAdditionalLimit: blocker.isAdditional,
            isBlocked: true,
            resetTimeOverride: headline.visibleResetTime,
            usesResetTimeOverride: true
        )
        if let existingIndex = rows.firstIndex(where: { $0.id == blockedRow.id }) {
            rows.remove(at: existingIndex)
            rows.insert(blockedRow, at: 0)
        } else if rows.isEmpty {
            rows = [blockedRow]
        } else {
            // Keep this source's existing row count stable: the blocker takes
            // the first selected slot instead of adding a row that could push
            // every following account into the overflow summary.
            rows[0] = blockedRow
        }
        return rows
    }

    private static func additionalRows(
        source: Source,
        metrics: UsageMetrics,
        health: WidgetDataHealth,
        preferences: WidgetPreferences,
        blockedIDs: Set<String>,
        now: Date
    ) -> [WidgetPresentationRow] {
        metrics.additionalLimits.enumerated().compactMap { index, limit in
            let window = widgetWindow(for: limit.periodKind)
            guard preferences.visibleQuotaWindows.contains(window) else { return nil }
            let idSuffix = "additional-\(index)"
            let isBlocked = blockedIDs.contains(idSuffix)
            return WidgetPresentationRow(
                id: "\(source.identifier.rawValue):\(idSuffix)",
                accountIdentifier: source.identifier,
                service: source.service,
                accountName: source.name,
                quotaWindow: window,
                modelLimitLabel: metrics.modelLimitLabel,
                limit: limit,
                health: health,
                displayMode: preferences.displayMode,
                preservesLegacyOpenRouterBalance: source.service == .openRouter
                    && preferences.preservesLegacyOpenRouterBalance,
                resetTime: preferences.showsResetTime
                    ? (isBlocked ? visibleResetTime(for: limit, now: now) : limit.resetTime)
                    : nil,
                freshnessDate: preferences.showsFreshness ? metrics.lastUpdated : nil,
                isBlocked: isBlocked,
                isAdditionalLimit: true
            )
        }
    }

    /// Additional periods reuse the existing session/weekly preference toggles
    /// rather than inventing a fourth widget slot.
    private static func widgetWindow(for periodKind: UsageLimit.PeriodKind?) -> WidgetQuotaWindow {
        switch periodKind {
        case .session, .daily:
            return .session
        case .weekly, .monthly, .billing, .unknown, nil:
            return .weekly
        }
    }

    private static func row(
        source: Source,
        idSuffix: String? = nil,
        window: WidgetQuotaWindow,
        limit: UsageLimit?,
        health: WidgetDataHealth,
        preferences: WidgetPreferences,
        isAdditionalLimit: Bool = false,
        isBlocked: Bool = false,
        resetTimeOverride: Date? = nil,
        usesResetTimeOverride: Bool = false
    ) -> WidgetPresentationRow {
        WidgetPresentationRow(
            id: "\(source.identifier.rawValue):\(idSuffix ?? window.rawValue)",
            accountIdentifier: source.identifier,
            service: source.service,
            accountName: source.name,
            quotaWindow: window,
            modelLimitLabel: source.metrics?.modelLimitLabel,
            limit: limit,
            health: health,
            displayMode: preferences.displayMode,
            preservesLegacyOpenRouterBalance: source.service == .openRouter
                && preferences.preservesLegacyOpenRouterBalance,
            resetTime: preferences.showsResetTime
                ? (usesResetTimeOverride ? resetTimeOverride : limit?.resetTime)
                : nil,
            freshnessDate: preferences.showsFreshness ? source.metrics?.lastUpdated : nil,
            isBlocked: isBlocked,
            isAdditionalLimit: isAdditionalLimit
        )
    }

    private static func blockingEvaluation(in metrics: UsageMetrics) -> ProviderBlockingEvaluation {
        ProviderBlockingPolicy.evaluate(
            service: metrics.service,
            extraUsage: metrics.extraUsage,
            candidates: limitCandidates(in: metrics).map(\.blockingCandidate)
        )
    }

    private static func limitCandidates(in metrics: UsageMetrics) -> [LimitCandidate] {
        var candidates: [LimitCandidate] = []
        if let limit = metrics.sessionLimit {
            candidates.append(LimitCandidate(
                idSuffix: WidgetQuotaWindow.session.rawValue,
                window: .session,
                limit: limit,
                isAdditional: false,
                blockingRole: .session
            ))
        }
        if let limit = metrics.weeklyLimit {
            candidates.append(LimitCandidate(
                idSuffix: WidgetQuotaWindow.weekly.rawValue,
                window: .weekly,
                limit: limit,
                isAdditional: false,
                blockingRole: .weekly
            ))
        }
        if let limit = metrics.codeReviewLimit {
            candidates.append(LimitCandidate(
                idSuffix: WidgetQuotaWindow.codeReview.rawValue,
                window: .codeReview,
                limit: limit,
                isAdditional: false,
                blockingRole: .secondary
            ))
        }
        candidates += metrics.additionalLimits.enumerated().map { index, limit in
            LimitCandidate(
                idSuffix: "additional-\(index)",
                window: widgetWindow(for: limit.periodKind),
                limit: limit,
                isAdditional: true,
                blockingRole: metrics.service == .cursor
                    && metrics.service.additionalQuotaTitleKey(for: limit) == .grokBot
                    ? .independentSubPool
                    : .secondary
            )
        }
        return candidates
    }

    private static func visibleResetTime(for limit: UsageLimit, now: Date) -> Date? {
        ProviderBlockingPolicy.headline(
            from: [ProviderBlockingCandidate(id: "row", role: .weekly, limit: limit)],
            now: now
        )?.visibleResetTime
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
