import Foundation

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
        String(format: "$%.2f", estimatedCostUSD)
    }

    var formattedTokens: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalTokens)) ?? "\(totalTokens)"
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
        String(format: "$%.2f", estimatedCostUSD)
    }

    var formattedTokens: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: totalTokens)) ?? "\(totalTokens)"
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
        String(format: "$%.2f", totalCostUSD)
    }

    var averageDailyCost: Double {
        guard periodDays > 0 else { return 0 }
        return totalCostUSD / Double(periodDays)
    }

    var formattedDailyCost: String {
        String(format: "$%.2f/day", averageDailyCost)
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
