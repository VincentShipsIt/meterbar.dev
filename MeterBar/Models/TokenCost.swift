import Foundation
import MeterBarShared

// Public: part of the MeterBar library's API surface consumed by the
// meterbar CLI (`meterbar cost` reads the app's cached CostSummary).
nonisolated public struct TokenCost: Codable, Identifiable, Sendable {
    public var id: String { provider.rawValue }

    public let provider: ServiceType
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    public let sessionCount: Int
    public let periodStart: Date
    public let periodEnd: Date
    public var modelBreakdowns: [TokenUsageBreakdown]
    public var originBreakdowns: [TokenUsageBreakdown]
    /// Per-project/worktree rollup (issue #270), derived from scanned session
    /// paths. Defaults to `[]` so existing call sites that don't group by
    /// project — and the CLI JSON fixture tests — see no shape change.
    public var projectBreakdowns: [TokenUsageBreakdown]

    public init(
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        sessionCount: Int,
        periodStart: Date,
        periodEnd: Date,
        modelBreakdowns: [TokenUsageBreakdown] = [],
        originBreakdowns: [TokenUsageBreakdown] = [],
        projectBreakdowns: [TokenUsageBreakdown] = []
    ) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.modelBreakdowns = modelBreakdowns
        self.originBreakdowns = originBreakdowns
        self.projectBreakdowns = projectBreakdowns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ServiceType.self, forKey: .provider)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try container.decode(Int.self, forKey: .cacheCreationTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        estimatedCostUSD = try container.decode(Double.self, forKey: .estimatedCostUSD)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        periodStart = try container.decode(Date.self, forKey: .periodStart)
        periodEnd = try container.decode(Date.self, forKey: .periodEnd)
        modelBreakdowns = try container.decodeIfPresent(
            [TokenUsageBreakdown].self,
            forKey: .modelBreakdowns
        ) ?? []
        originBreakdowns = try container.decodeIfPresent(
            [TokenUsageBreakdown].self,
            forKey: .originBreakdowns
        ) ?? []
        projectBreakdowns = try container.decodeIfPresent(
            [TokenUsageBreakdown].self,
            forKey: .projectBreakdowns
        ) ?? []
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }

    public var formattedTokens: String {
        UsageFormat.groupedTokens(totalTokens)
    }
}

nonisolated public struct TokenUsageBreakdown: Codable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(name)" }

    public let provider: ServiceType
    public let name: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    public let sessionCount: Int
    /// Nested per-model slice of this row's spend (issue #270). Populated
    /// only for project rollup rows, via `TokenUsageAggregator.makeProjectBreakdowns`;
    /// every other breakdown (model, origin) defaults to `[]` so existing
    /// call sites and the CLI JSON fixtures are unaffected.
    public let modelBreakdowns: [TokenUsageBreakdown]

    public init(
        provider: ServiceType,
        name: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        sessionCount: Int,
        modelBreakdowns: [TokenUsageBreakdown] = []
    ) {
        self.provider = provider
        self.name = name
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
        self.modelBreakdowns = modelBreakdowns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ServiceType.self, forKey: .provider)
        name = try container.decode(String.self, forKey: .name)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try container.decode(Int.self, forKey: .cacheCreationTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        estimatedCostUSD = try container.decode(Double.self, forKey: .estimatedCostUSD)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        modelBreakdowns = try container.decodeIfPresent(
            [TokenUsageBreakdown].self,
            forKey: .modelBreakdowns
        ) ?? []
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }

    public var formattedTokens: String {
        UsageFormat.groupedTokens(totalTokens)
    }
}

nonisolated public struct DailyTokenUsage: Codable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(Self.dayFormatter.string(from: date))" }

    public let date: Date
    public let provider: ServiceType
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    /// Day × model attribution from the v2 cost cache. `nil` means the row
    /// came from a v1 cache that predates attribution; an empty array means a
    /// v2 scan ran but had no model rows.
    public let modelBreakdowns: [TokenUsageBreakdown]?
    /// Day × project attribution, including each project's model slice.
    /// Project names have already passed through `CostProjectAttribution`;
    /// raw paths are never persisted here.
    public let projectBreakdowns: [TokenUsageBreakdown]?

    public init(
        date: Date,
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        modelBreakdowns: [TokenUsageBreakdown]? = nil,
        projectBreakdowns: [TokenUsageBreakdown]? = nil
    ) {
        self.date = date
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.modelBreakdowns = modelBreakdowns
        self.projectBreakdowns = projectBreakdowns
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One provider's token usage inside a local calendar-hour bucket.
///
/// Hourly rows intentionally stop at the same aggregate shape as daily rows:
/// the seven-day activity heatmap needs provider totals, not model or project
/// attribution. `date` is always the start of the represented local hour.
nonisolated public struct HourlyTokenUsage: Codable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(date.timeIntervalSinceReferenceDate)" }

    public let date: Date
    public let provider: ServiceType
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double

    public init(
        date: Date,
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double
    ) {
        self.date = date
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }
}

nonisolated public struct LifetimeProviderCost: Codable, Identifiable, Equatable, Sendable {
    public var id: String { provider.rawValue }

    public let provider: ServiceType
    public let estimatedCostUSD: Double
    public let firstTrackedDate: Date
    public let lastTrackedDate: Date

    public init(
        provider: ServiceType,
        estimatedCostUSD: Double,
        firstTrackedDate: Date,
        lastTrackedDate: Date
    ) {
        self.provider = provider
        self.estimatedCostUSD = estimatedCostUSD
        self.firstTrackedDate = firstTrackedDate
        self.lastTrackedDate = lastTrackedDate
    }

    public var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }
}

/// A complete, point-in-time total over every billable local session currently
/// available to CostTracker. Each scan replaces this snapshot instead of
/// merging with the previous cache, so overlapping or repeated scans cannot
/// inflate the lifetime total.
nonisolated public struct LifetimeCostSummary: Codable, Equatable, Sendable {
    public let providers: [LifetimeProviderCost]
    public let totalCostUSD: Double
    public let firstTrackedDate: Date?
    public let lastTrackedDate: Date?

    public init(costs: [TokenCost]) {
        var byProvider: [ServiceType: LifetimeProviderCost] = [:]

        for cost in costs where cost.estimatedCostUSD > 0 {
            let existing = byProvider[cost.provider]
            byProvider[cost.provider] = LifetimeProviderCost(
                provider: cost.provider,
                estimatedCostUSD: (existing?.estimatedCostUSD ?? 0) + cost.estimatedCostUSD,
                firstTrackedDate: min(existing?.firstTrackedDate ?? cost.periodStart, cost.periodStart),
                lastTrackedDate: max(existing?.lastTrackedDate ?? cost.periodEnd, cost.periodEnd)
            )
        }

        self.init(providers: byProvider.values.sorted { $0.provider.rawValue < $1.provider.rawValue })
    }

    private init(providers: [LifetimeProviderCost]) {
        self.providers = providers
        totalCostUSD = providers.reduce(0) { $0 + $1.estimatedCostUSD }
        firstTrackedDate = providers.map(\.firstTrackedDate).min()
        lastTrackedDate = providers.map(\.lastTrackedDate).max()
    }

    public var hasBillableHistory: Bool {
        !providers.isEmpty && totalCostUSD > 0
    }

    public var formattedTotalCost: String {
        UsageFormat.cost(totalCostUSD)
    }

    public func filtered(to enabledServices: Set<ServiceType>) -> LifetimeCostSummary {
        LifetimeCostSummary(providers: providers.filter { enabledServices.contains($0.provider) })
    }
}

nonisolated public struct CostSummary: Codable, Sendable {
    public let costs: [TokenCost]
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let periodDays: Int
    public let dailyUsage: [DailyTokenUsage]
    /// Provider rows for the trailing seven calendar days, bucketed at each
    /// local hour start. Optional so caches written before issue #372 decode.
    public let hourlyUsage: [HourlyTokenUsage]?
    public let lifetime: LifetimeCostSummary?
    /// Which dated rate entries actually priced this scan, and how many events
    /// predated the table (issue #339). Optional so summaries cached by builds
    /// that predate dated pricing still decode; readers fall back to
    /// `ModelPricing.tableProvenance`.
    public let pricing: PricingProvenance?

    public init(
        costs: [TokenCost],
        totalCostUSD: Double,
        totalTokens: Int,
        periodDays: Int,
        dailyUsage: [DailyTokenUsage] = [],
        hourlyUsage: [HourlyTokenUsage]? = nil,
        lifetime: LifetimeCostSummary? = nil,
        pricing: PricingProvenance? = nil
    ) {
        self.costs = costs
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.periodDays = periodDays
        self.dailyUsage = dailyUsage
        self.hourlyUsage = hourlyUsage
        self.lifetime = lifetime
        self.pricing = pricing
    }

    public var formattedTotalCost: String {
        UsageFormat.cost(totalCostUSD)
    }

    public var averageDailyCost: Double {
        guard periodDays > 0 else { return 0 }
        return totalCostUSD / Double(periodDays)
    }

    public var formattedDailyCost: String {
        "\(UsageFormat.cost(averageDailyCost))/day"
    }

    /// Whether the cached summary is missing daily rows inside the visible window
    /// and should be quietly backfilled. Returns `false` once a scan has already
    /// run today (a genuinely zero-usage day shouldn't trigger constant rescans),
    /// but `true` for legacy caches that have costs/tokens yet no daily rows.
    func needsMissingDailyUsageRefresh(
        days: Int,
        lastScanDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !costs.isEmpty, totalTokens > 0 else { return false }
        guard !dailyUsage.isEmpty else { return true }
        guard dailyUsage.allSatisfy({
            $0.modelBreakdowns != nil && $0.projectBreakdowns != nil
        }) else {
            return true
        }

        let today = calendar.startOfDay(for: now)
        if let lastScanDate,
           calendar.startOfDay(for: lastScanDate) >= today {
            return false
        }

        let daysToCheck = max(1, days)
        let startDate = calendar.date(byAdding: .day, value: -(daysToCheck - 1), to: today) ?? today
        let populatedDays = Set(dailyUsage.compactMap { usage -> Date? in
            let day = calendar.startOfDay(for: usage.date)
            guard day >= startDate, day <= today else { return nil }
            return day
        })

        return populatedDays.count < daysToCheck
    }

    /// Whether a cache that should cover the seven-day activity window still
    /// predates hourly rows. A completed scan today is authoritative even when
    /// it found no hourly usage, preventing an empty week from rescanning on
    /// every Costs-page appearance.
    func needsMissingHourlyUsageRefresh(
        lastScanDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !costs.isEmpty, totalTokens > 0, periodDays >= 7 else { return false }

        let today = calendar.startOfDay(for: now)
        if let lastScanDate,
           calendar.startOfDay(for: lastScanDate) >= today {
            return false
        }

        return hourlyUsage?.isEmpty != false
    }

    /// Aggregates the cached daily rows into per-provider totals over the last
    /// `days` calendar days (inclusive of today). Pure and rescan-free: it reads
    /// only `dailyUsage`, so it can report input/output/cache-read tokens and
    /// cost — not cache-creation tokens or session counts, which daily rows
    /// don't carry. Powers `meterbar cost --days N` (issue #26).
    ///
    /// `coveredDays` is bounded by the last scan window (`periodDays`) *and* the
    /// actual span of cached daily rows (earliest row → today). `periodDays`
    /// alone is just the requested scan width — a fresh install scanned with
    /// `days: 30` but holding 2 real days of rows must still report 2, not 30,
    /// so callers can surface under-coverage rather than imply a full window.
    public func dailyCostWindow(
        lastDays days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyCostWindow {
        let requestedDays = max(1, days)
        let today = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: today) ?? today

        let windowRows = dailyUsage.filter { row in
            let day = calendar.startOfDay(for: row.date)
            return day >= startDate && day <= today
        }

        let providers = Dictionary(grouping: windowRows, by: \.provider)
            .map { provider, rows in
                let hasCompleteModels = rows.allSatisfy { $0.modelBreakdowns != nil }
                let hasCompleteProjects = rows.allSatisfy { $0.projectBreakdowns != nil }
                return ProviderDailyTotal(
                    provider: provider,
                    inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                    outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                    cacheReadTokens: rows.reduce(0) { $0 + $1.cacheReadTokens },
                    estimatedCostUSD: rows.reduce(0) { $0 + $1.estimatedCostUSD },
                    modelBreakdowns: hasCompleteModels
                        ? TokenUsageBreakdownAggregation.merge(rows.flatMap { $0.modelBreakdowns ?? [] })
                        : nil,
                    projectBreakdowns: hasCompleteProjects
                        ? TokenUsageBreakdownAggregation.merge(rows.flatMap { $0.projectBreakdowns ?? [] })
                        : nil
                )
            }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }

        // Days the cache demonstrably spans: earliest daily row through today,
        // inclusive. Zero-usage days inside that span carry no row, so this is
        // a conservative lower bound — better a spurious "only N days" notice
        // than silently presenting 2 days of data as a 30-day total.
        let cachedSpanDays: Int
        let pastDays = dailyUsage
            .map { calendar.startOfDay(for: $0.date) }
            .filter { $0 <= today }
        if let earliestDay = pastDays.min() {
            let dayGap = calendar.dateComponents([.day], from: earliestDay, to: today).day ?? 0
            cachedSpanDays = max(0, dayGap) + 1
        } else {
            cachedSpanDays = 0
        }

        return DailyCostWindow(
            requestedDays: requestedDays,
            coveredDays: min(requestedDays, min(periodDays, cachedSpanDays)),
            providers: providers,
            totalCostUSD: providers.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: providers.reduce(0) { $0 + $1.totalTokens }
        )
    }

    /// Calendar month-to-date window (issue #270): the 1st of `now`'s local
    /// month through `now`, inclusive. A month-to-date span is exactly a
    /// "last N days" window where N is the day-count since the 1st, so this
    /// delegates straight to `dailyCostWindow` instead of duplicating its
    /// filtering/aggregation/truncation logic. `now`/`calendar` are read
    /// fresh on every call — never cached — so the window rolls over at
    /// midnight on the 1st without a restart or rescan.
    public func monthToDateCostWindow(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyCostWindow {
        let today = calendar.startOfDay(for: now)
        let monthStart = CostWindow.startOfCurrentMonth(now: now, calendar: calendar)
        let daysElapsed = (calendar.dateComponents([.day], from: monthStart, to: today).day ?? 0) + 1
        return dailyCostWindow(lastDays: daysElapsed, now: now, calendar: calendar)
    }

    public func filtered(to enabledServices: Set<ServiceType>) -> CostSummary {
        let visibleCosts = costs.filter { enabledServices.contains($0.provider) }
        let visibleDailyUsage = dailyUsage.filter { enabledServices.contains($0.provider) }
        let visibleHourlyUsage = hourlyUsage?.filter { enabledServices.contains($0.provider) }

        return CostSummary(
            costs: visibleCosts,
            totalCostUSD: visibleCosts.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: visibleCosts.reduce(0) { $0 + $1.totalTokens },
            periodDays: periodDays,
            dailyUsage: visibleDailyUsage,
            hourlyUsage: visibleHourlyUsage,
            lifetime: lifetime?.filtered(to: enabledServices)
        )
    }
}

/// Per-provider token/cost totals summed over a day window (see
/// `CostSummary.dailyCostWindow`). Public: part of the `meterbar cost --days`
/// output surface.
nonisolated public struct ProviderDailyTotal: Codable, Sendable, Identifiable {
    public var id: String { provider.rawValue }

    public let provider: ServiceType
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    /// `nil` when any included row predates cache v2; otherwise the model
    /// rollup over exactly the same days as this provider total.
    public let modelBreakdowns: [TokenUsageBreakdown]?
    /// `nil` when any included row predates cache v2; otherwise the project
    /// rollup (with nested models) over exactly the same days.
    public let projectBreakdowns: [TokenUsageBreakdown]?

    public init(
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        modelBreakdowns: [TokenUsageBreakdown]? = nil,
        projectBreakdowns: [TokenUsageBreakdown]? = nil
    ) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.modelBreakdowns = modelBreakdowns
        self.projectBreakdowns = projectBreakdowns
    }

    /// Daily rows omit cache-creation tokens, so this is input + output + cache-read.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }

    public var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }
}

/// Result of windowing the cached daily cost rows to the last N days
/// (`CostSummary.dailyCostWindow`). Codable so `meterbar cost --days N --json`
/// can emit it directly.
nonisolated public struct DailyCostWindow: Codable, Sendable {
    /// Days requested via `--days N` (clamped to ≥ 1).
    public let requestedDays: Int
    /// Days the cache can actually cover: the requested window clamped to both
    /// the last scan width (`periodDays`) and the real span of cached daily rows.
    public let coveredDays: Int
    /// Per-provider totals over the window, sorted by provider raw value.
    public let providers: [ProviderDailyTotal]
    public let totalCostUSD: Double
    public let totalTokens: Int

    public init(
        requestedDays: Int,
        coveredDays: Int,
        providers: [ProviderDailyTotal],
        totalCostUSD: Double,
        totalTokens: Int
    ) {
        self.requestedDays = requestedDays
        self.coveredDays = coveredDays
        self.providers = providers
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
    }

    /// The cache spans fewer days than requested — output should say so rather
    /// than imply the full window was covered.
    public var isTruncated: Bool {
        coveredDays < requestedDays
    }

    public var formattedTotalCost: String {
        UsageFormat.cost(totalCostUSD)
    }
}

/// Sums persisted day-level attribution without repricing it. Daily rows
/// already carry the exact model-aware estimated cost produced by the scan, so
/// recomputing from provider defaults here could drift from the provider total.
nonisolated private enum TokenUsageBreakdownAggregation {
    static func merge(_ rows: [TokenUsageBreakdown]) -> [TokenUsageBreakdown] {
        var byName: [String: TokenUsageBreakdown] = [:]

        for row in rows {
            let existing = byName[row.name]
            byName[row.name] = TokenUsageBreakdown(
                provider: row.provider,
                name: row.name,
                inputTokens: (existing?.inputTokens ?? 0) + row.inputTokens,
                outputTokens: (existing?.outputTokens ?? 0) + row.outputTokens,
                cacheCreationTokens: (existing?.cacheCreationTokens ?? 0) + row.cacheCreationTokens,
                cacheReadTokens: (existing?.cacheReadTokens ?? 0) + row.cacheReadTokens,
                estimatedCostUSD: (existing?.estimatedCostUSD ?? 0) + row.estimatedCostUSD,
                sessionCount: (existing?.sessionCount ?? 0) + row.sessionCount,
                modelBreakdowns: merge((existing?.modelBreakdowns ?? []) + row.modelBreakdowns)
            )
        }

        return byName.values.sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }
}
