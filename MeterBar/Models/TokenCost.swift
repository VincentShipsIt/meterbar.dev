import Foundation
import MeterBarShared

// Public: part of the MeterBar library's API surface consumed by the
// meterbar CLI (`meterbar cost` reads the app's cached CostSummary).
public struct TokenCost: Codable, Identifiable, Sendable {
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
        originBreakdowns: [TokenUsageBreakdown] = []
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

public struct TokenUsageBreakdown: Codable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(name)" }

    public let provider: ServiceType
    public let name: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double
    public let sessionCount: Int

    public init(
        provider: ServiceType,
        name: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double,
        sessionCount: Int
    ) {
        self.provider = provider
        self.name = name
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
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

public struct DailyTokenUsage: Codable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)-\(Self.dayFormatter.string(from: date))" }

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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public struct CostSummary: Codable, Sendable {
    public let costs: [TokenCost]
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let periodDays: Int
    public let dailyUsage: [DailyTokenUsage]

    public init(
        costs: [TokenCost],
        totalCostUSD: Double,
        totalTokens: Int,
        periodDays: Int,
        dailyUsage: [DailyTokenUsage] = []
    ) {
        self.costs = costs
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.periodDays = periodDays
        self.dailyUsage = dailyUsage
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

    /// Aggregates the cached daily rows into per-provider totals over the last
    /// `days` calendar days (inclusive of today). Pure and rescan-free: it reads
    /// only `dailyUsage`, so it can report input/output/cache-read tokens and
    /// cost — not cache-creation tokens or session counts, which daily rows
    /// don't carry. Powers `meterbar cost --days N` (issue #26).
    ///
    /// `coveredDays` is `min(days, periodDays)`: when the cache spans fewer days
    /// than requested, callers should surface that rather than imply full
    /// coverage.
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

        var byProvider: [ServiceType: ProviderDailyTotal] = [:]
        for row in windowRows {
            let existing = byProvider[row.provider]
            byProvider[row.provider] = ProviderDailyTotal(
                provider: row.provider,
                inputTokens: (existing?.inputTokens ?? 0) + row.inputTokens,
                outputTokens: (existing?.outputTokens ?? 0) + row.outputTokens,
                cacheReadTokens: (existing?.cacheReadTokens ?? 0) + row.cacheReadTokens,
                estimatedCostUSD: (existing?.estimatedCostUSD ?? 0) + row.estimatedCostUSD
            )
        }

        let providers = byProvider.values.sorted { $0.provider.rawValue < $1.provider.rawValue }

        return DailyCostWindow(
            requestedDays: requestedDays,
            coveredDays: min(requestedDays, periodDays),
            providers: providers,
            totalCostUSD: providers.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: providers.reduce(0) { $0 + $1.totalTokens }
        )
    }

    public func filtered(to enabledServices: Set<ServiceType>) -> CostSummary {
        let visibleCosts = costs.filter { enabledServices.contains($0.provider) }
        let visibleDailyUsage = dailyUsage.filter { enabledServices.contains($0.provider) }

        return CostSummary(
            costs: visibleCosts,
            totalCostUSD: visibleCosts.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: visibleCosts.reduce(0) { $0 + $1.totalTokens },
            periodDays: periodDays,
            dailyUsage: visibleDailyUsage
        )
    }
}

/// Per-provider token/cost totals summed over a day window (see
/// `CostSummary.dailyCostWindow`). Public: part of the `meterbar cost --days`
/// output surface.
public struct ProviderDailyTotal: Codable, Sendable, Identifiable {
    public var id: String { provider.rawValue }

    public let provider: ServiceType
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double

    public init(
        provider: ServiceType,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        estimatedCostUSD: Double
    ) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
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
public struct DailyCostWindow: Codable, Sendable {
    /// Days requested via `--days N` (clamped to ≥ 1).
    public let requestedDays: Int
    /// Days the cache can actually cover: `min(requestedDays, periodDays)`.
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
