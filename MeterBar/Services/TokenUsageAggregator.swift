import Foundation
import MeterBarShared

/// Folds the per-bucket `TokenAccumulator` totals a scan produces into the
/// daily-usage rows and breakdown rows the UI renders.
/// Split out of `CostTracker` (audit C1d).
enum TokenUsageAggregator {
    nonisolated static func makeDailyUsage(
        from dailyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [DailyTokenUsage] {
        dailyTotals.map { day, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : TokenCostMath.calculateCost(
                    input: billableInput,
                    output: tokens.output + tokens.reasoning,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: pricing
                )
            return DailyTokenUsage(
                date: day,
                provider: provider,
                inputTokens: billableInput,
                outputTokens: tokens.output + tokens.reasoning,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost
            )
        }
    }

    /// `pricingForName` lets a provider price each row by its own model instead
    /// of the flat provider rate. Codex slugs all bill at the same published
    /// rate today, so rows still sum to the provider total.
    nonisolated static func makeBreakdowns(
        from totals: [String: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing,
        pricingForName: ((String) -> TokenPricing)? = nil
    ) -> [TokenUsageBreakdown] {
        totals.map { name, tokens in
            let rowPricing = pricingForName?(name) ?? pricing
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let output = tokens.output + tokens.reasoning
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : TokenCostMath.calculateCost(
                    input: billableInput,
                    output: output,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: rowPricing
                )
            return TokenUsageBreakdown(
                provider: provider,
                name: name,
                inputTokens: billableInput,
                outputTokens: output,
                cacheCreationTokens: tokens.cacheCreation,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost,
                sessionCount: tokens.events
            )
        }
        .sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }
}
