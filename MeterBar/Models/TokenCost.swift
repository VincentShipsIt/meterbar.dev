import Foundation
import MeterBarShared

struct TokenCost: Codable, Identifiable, Sendable {
    var id: String { provider.rawValue }

    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
    let periodStart: Date
    let periodEnd: Date
    var modelBreakdowns: [TokenUsageBreakdown] = []
    var originBreakdowns: [TokenUsageBreakdown] = []

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }

    var formattedTokens: String {
        UsageFormat.groupedTokens(totalTokens)
    }
}

struct TokenUsageBreakdown: Codable, Identifiable, Sendable {
    var id: String { "\(provider.rawValue)-\(name)" }

    let provider: ServiceType
    let name: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var formattedCost: String {
        UsageFormat.cost(estimatedCostUSD)
    }

    var formattedTokens: String {
        UsageFormat.groupedTokens(totalTokens)
    }
}

struct DailyTokenUsage: Codable, Identifiable, Sendable {
    var id: String { "\(provider.rawValue)-\(Self.dayFormatter.string(from: date))" }

    let date: Date
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct CostSummary: Codable, Sendable {
    let costs: [TokenCost]
    let totalCostUSD: Double
    let totalTokens: Int
    let periodDays: Int
    let dailyUsage: [DailyTokenUsage]

    init(
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

    var formattedTotalCost: String {
        UsageFormat.cost(totalCostUSD)
    }

    var averageDailyCost: Double {
        guard periodDays > 0 else { return 0 }
        return totalCostUSD / Double(periodDays)
    }

    var formattedDailyCost: String {
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

    func filtered(to enabledServices: Set<ServiceType>) -> CostSummary {
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
