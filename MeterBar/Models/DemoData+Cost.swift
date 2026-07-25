import Foundation
import MeterBarShared

/// App-target demo cost fixture.
///
/// `CostSummary`/`TokenCost`/`DailyTokenUsage` live in the app target (not
/// `MeterBarShared`), so the cost half of demo mode is an app-side extension on
/// the shared `DemoData` namespace. `CostTracker` publishes this instead of
/// scanning real CLI logs when demo mode is active.
///
/// The summary is deliberately **non-alarming** — a ~$205 30-day estimate split
/// across three providers — and carries **no origin or model breakdowns**, so
/// it never surfaces the owner's real project paths or private model routing.
/// Daily rows are a smooth, deterministic weekly rhythm so the cost chart reads
/// as populated and healthy in screenshots. Everything is a pure function of
/// `now`.
extension DemoData {
    /// Per-provider 30-day totals (USD) and token magnitudes for the demo cost
    /// summary. Sums to $204.90 ≈ "$205".
    private struct DemoProviderCost {
        let provider: ServiceType
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let costUSD: Double
        let sessionCount: Int
    }

    private static let demoProviderCosts: [DemoProviderCost] = [
        DemoProviderCost(
            provider: .claudeCode,
            inputTokens: 3_200_000,
            outputTokens: 1_100_000,
            cacheCreationTokens: 900_000,
            cacheReadTokens: 42_000_000,
            costUSD: 95.40,
            sessionCount: 128
        ),
        DemoProviderCost(
            provider: .codexCli,
            inputTokens: 5_400_000,
            outputTokens: 1_800_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 68.20,
            sessionCount: 96
        ),
        // Cursor is billed in dollars, not tokens, so it contributes cost only.
        DemoProviderCost(
            provider: .cursor,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 41.30,
            sessionCount: 54
        )
    ]

    private static let demoPeriodDays = 30

    /// Synthetic 30-day cost summary for demo mode.
    static func costSummary(now: Date = Date(), calendar: Calendar = .current) -> CostSummary {
        let periodEnd = now
        let periodStart = calendar.date(byAdding: .day, value: -demoPeriodDays, to: now) ?? now

        let costs = demoProviderCosts.map { provider in
            TokenCost(
                provider: provider.provider,
                inputTokens: provider.inputTokens,
                outputTokens: provider.outputTokens,
                cacheCreationTokens: provider.cacheCreationTokens,
                cacheReadTokens: provider.cacheReadTokens,
                estimatedCostUSD: provider.costUSD,
                sessionCount: provider.sessionCount,
                periodStart: periodStart,
                periodEnd: periodEnd,
                modelBreakdowns: [],
                originBreakdowns: []
            )
        }

        let totalCostUSD = costs.reduce(0) { $0 + $1.estimatedCostUSD }
        let totalTokens = costs.reduce(0) { $0 + $1.totalTokens }

        return CostSummary(
            costs: costs,
            totalCostUSD: totalCostUSD,
            totalTokens: totalTokens,
            periodDays: demoPeriodDays,
            dailyUsage: dailyUsage(periodEnd: periodEnd, calendar: calendar),
            lifetime: nil
        )
    }

    /// One row per token-billed provider per day across the 30-day window,
    /// following a fixed weekly weight pattern so the chart looks lived-in
    /// without any random noise.
    private static func dailyUsage(periodEnd: Date, calendar: Calendar) -> [DailyTokenUsage] {
        // Lighter usage on weekend-position indices; heavier midweek. Deterministic.
        let weeklyWeights = [3, 6, 7, 6, 7, 5, 2]
        let today = calendar.startOfDay(for: periodEnd)

        return demoProviderCosts
            .filter { $0.inputTokens > 0 || $0.outputTokens > 0 }
            .flatMap { provider -> [DailyTokenUsage] in
                let weightTotal = (0..<demoPeriodDays).reduce(0) { sum, index in
                    sum + weeklyWeights[index % weeklyWeights.count]
                }
                return (0..<demoPeriodDays).compactMap { index -> DailyTokenUsage? in
                    guard let date = calendar.date(
                        byAdding: .day,
                        value: -(demoPeriodDays - 1 - index),
                        to: today
                    ) else { return nil }
                    let weight = Double(weeklyWeights[index % weeklyWeights.count])
                    let fraction = weight / Double(weightTotal)
                    return DailyTokenUsage(
                        date: date,
                        provider: provider.provider,
                        inputTokens: Int(Double(provider.inputTokens) * fraction),
                        outputTokens: Int(Double(provider.outputTokens) * fraction),
                        cacheReadTokens: Int(Double(provider.cacheReadTokens) * fraction),
                        estimatedCostUSD: provider.costUSD * fraction
                    )
                }
            }
    }
}
