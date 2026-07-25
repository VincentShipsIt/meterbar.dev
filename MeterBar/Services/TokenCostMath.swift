import Foundation
import MeterBarShared

/// The single pricing formula every provider, day, and breakdown row runs
/// through. Split out of `CostTracker` (audit C1d).
enum TokenCostMath {
    /// Cost without a one-hour cache tier — delegates to `calculateClaudeCost`
    /// so there is exactly one pricing formula. (These were near-duplicates
    /// that had drifted: only the Claude variant clamped negative inputs.)
    nonisolated static func calculateCost(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        pricing: TokenPricing
    ) -> Double {
        calculateClaudeCost(
            input: input,
            output: output,
            cacheCreation: cacheCreation,
            cacheCreationOneHour: 0,
            cacheRead: cacheRead,
            pricing: pricing
        )
    }

    nonisolated static func calculateClaudeCost(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheCreationOneHour: Int,
        cacheRead: Int,
        pricing: TokenPricing
    ) -> Double {
        let oneHourCacheCreation = min(max(0, cacheCreationOneHour), max(0, cacheCreation))
        let fiveMinuteCacheCreation = max(0, cacheCreation - oneHourCacheCreation)
        let oneHourRate = pricing.cacheCreationOneHour ?? pricing.cacheCreation

        let inputCost = Double(max(0, input)) / 1_000_000 * pricing.input
        let outputCost = Double(max(0, output)) / 1_000_000 * pricing.output
        let cacheCreationCost = Double(fiveMinuteCacheCreation) / 1_000_000 * pricing.cacheCreation
        let oneHourCacheCreationCost = Double(oneHourCacheCreation) / 1_000_000 * oneHourRate
        let cacheReadCost = Double(max(0, cacheRead)) / 1_000_000 * pricing.cacheRead
        return inputCost + outputCost + cacheCreationCost + oneHourCacheCreationCost + cacheReadCost
    }
}
