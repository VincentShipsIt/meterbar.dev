import Foundation
import MeterBarShared

/// App-target demo cost fixture.
///
/// `CostSummary`/`TokenCost`/`DailyTokenUsage` live in the app target (not
/// `MeterBarShared`), so the cost half of demo mode is an app-side extension on
/// the shared `DemoData` namespace. `CostTracker` publishes this instead of
/// scanning real CLI logs when demo mode is active.
///
/// The summary is deliberately **non-alarming** — a ~$240 30-day estimate split
/// across every provider. Model and origin breakdowns are **fully synthetic**,
/// drawn from `syntheticBreakdownNames` only (public model ids and generic
/// origin labels), so the model-spend and origin charts render in screenshots
/// without ever surfacing the owner's real project paths or private routing.
/// Daily rows are a smooth, deterministic weekly rhythm so the cost chart reads
/// as populated and healthy in screenshots. Everything is a pure function of
/// `now`.
extension DemoData {
    /// The only names demo breakdowns may carry — public model identifiers and
    /// generic origin labels. Internal (not private) so the leak test can pin
    /// every rendered breakdown row to this vocabulary.
    static let syntheticBreakdownNames: Set<String> = [
        "claude-fable-5", "claude-opus-5", "claude-haiku-4-5",
        "gpt-5.6-sol", "gpt-5.6-luna",
        "grok-4.5-build", "grok-4.5",
        "Main chat", "Agents", "Code review",
    ]

    /// One named slice of a provider's synthetic spend. Fractions per provider
    /// sum to 1 so the breakdown reconciles exactly — a demo chart must never
    /// show an "Unattributed" remainder.
    private struct DemoSplit {
        let name: String
        let fraction: Double
    }

    private static let demoModelSplits: [ServiceType: [DemoSplit]] = [
        .claudeCode: [
            DemoSplit(name: "claude-fable-5", fraction: 0.52),
            DemoSplit(name: "claude-opus-5", fraction: 0.31),
            DemoSplit(name: "claude-haiku-4-5", fraction: 0.17),
        ],
        .codexCli: [
            DemoSplit(name: "gpt-5.6-sol", fraction: 0.72),
            DemoSplit(name: "gpt-5.6-luna", fraction: 0.28),
        ],
        .grok: [
            DemoSplit(name: "grok-4.5-build", fraction: 0.74),
            DemoSplit(name: "grok-4.5", fraction: 0.26),
        ],
    ]

    private static let demoOriginSplits: [ServiceType: [DemoSplit]] = [
        .claudeCode: [
            DemoSplit(name: "Main chat", fraction: 0.44),
            DemoSplit(name: "Agents", fraction: 0.38),
            DemoSplit(name: "Code review", fraction: 0.18),
        ],
        .codexCli: [
            DemoSplit(name: "Main chat", fraction: 0.57),
            DemoSplit(name: "Agents", fraction: 0.43),
        ],
        .grok: [
            DemoSplit(name: "Main chat", fraction: 0.61),
            DemoSplit(name: "Agents", fraction: 0.39),
        ],
    ]

    /// Slices token/cost totals along `splits`. Token counts truncate — nothing
    /// asserts on their sums — but the dollar fractions add back to the total.
    private static func syntheticBreakdowns(
        splits: [DemoSplit],
        of totals: DemoProviderCost
    ) -> [TokenUsageBreakdown] {
        splits.map { split in
            TokenUsageBreakdown(
                provider: totals.provider,
                name: split.name,
                inputTokens: Int(Double(totals.inputTokens) * split.fraction),
                outputTokens: Int(Double(totals.outputTokens) * split.fraction),
                cacheCreationTokens: Int(Double(totals.cacheCreationTokens) * split.fraction),
                cacheReadTokens: Int(Double(totals.cacheReadTokens) * split.fraction),
                estimatedCostUSD: totals.costUSD * split.fraction,
                sessionCount: max(1, Int(Double(totals.sessionCount) * split.fraction))
            )
        }
    }
    /// Per-provider 30-day totals (USD) and token magnitudes for the demo cost
    /// summary. Sums to $240.10 ≈ "$240".
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
        ),
        DemoProviderCost(
            provider: .grok,
            inputTokens: 1_850_000,
            outputTokens: 610_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 22.40,
            sessionCount: 41
        ),
        // OpenRouter is billed in dollars, not tokens, so it contributes cost only.
        DemoProviderCost(
            provider: .openRouter,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 12.80,
            sessionCount: 18
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
                modelBreakdowns: syntheticBreakdowns(
                    splits: demoModelSplits[provider.provider] ?? [],
                    of: provider
                ),
                originBreakdowns: syntheticBreakdowns(
                    splits: demoOriginSplits[provider.provider] ?? [],
                    of: provider
                )
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
                    let dayInput = Int(Double(provider.inputTokens) * fraction)
                    let dayOutput = Int(Double(provider.outputTokens) * fraction)
                    let dayCacheRead = Int(Double(provider.cacheReadTokens) * fraction)
                    let dayCost = provider.costUSD * fraction
                    return DailyTokenUsage(
                        date: date,
                        provider: provider.provider,
                        inputTokens: dayInput,
                        outputTokens: dayOutput,
                        cacheReadTokens: dayCacheRead,
                        estimatedCostUSD: dayCost,
                        // Per-day model attribution, so the 7-day window's model
                        // chart re-derives from these rows like it does for a
                        // real v2 cache instead of falling back to the
                        // scan-period detail and the mismatch caption.
                        modelBreakdowns: syntheticBreakdowns(
                            splits: demoModelSplits[provider.provider] ?? [],
                            of: DemoProviderCost(
                                provider: provider.provider,
                                inputTokens: dayInput,
                                outputTokens: dayOutput,
                                cacheCreationTokens: 0,
                                cacheReadTokens: dayCacheRead,
                                costUSD: dayCost,
                                sessionCount: 1
                            )
                        )
                    )
                }
            }
    }
}
