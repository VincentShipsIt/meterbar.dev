import Foundation
import MeterBarShared

/// Turns the accumulated ledger into the same cost/daily/hourly tuple the log
/// scanners produce, so a provider with no local corpus lands in
/// `costs[]`/`dailyUsage[]` through exactly the same fold. Poll-only providers
/// have no event timestamps, so their hourly slice is intentionally empty.
///
/// The counterpart to `ClaudeCostScanner.makeCost` and friends, and deliberately
/// the *only* path from the ledger into money: it emits nothing for an entry
/// that is not denominated in dollars.
nonisolated enum ProviderUsageCostBuilder {
    /// One provider's window, or `nil` when it has nothing to contribute.
    ///
    /// Every token count is zero, and that is the honest answer rather than a
    /// missing one: OpenRouter's key endpoint reports spend and no token counts
    /// at all, so any figure here would be invented. Breakdowns are `[]` for the
    /// same reason — the provider publishes no per-model or per-project split —
    /// and emphatically not `nil`, which `CostSummary.needsMissingDailyUsageRefresh`
    /// reads as "this row predates attribution, rescan", re-triggering a full
    /// corpus scan on every refresh forever.
    ///
    /// - Parameter windowStart: the reporting cutoff; `.distantPast` for the
    ///   lifetime window, which for these providers means "everything MeterBar
    ///   has observed" and never the provider's own pre-install total.
    static func makeCost(
        from ledger: ProviderUsageLedger,
        provider: ServiceType,
        windowStart: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (TokenCost, [DailyTokenUsage], [HourlyTokenUsage])? {
        let cutoff = calendar.startOfDay(for: windowStart)
        let today = calendar.startOfDay(for: now)
        // Days are only ever written by an observation, so a future-dated one
        // means the clock moved backwards; it is dropped rather than drawn off
        // the right edge of the chart.
        let days = ledger.dailyUSDSeries(for: provider)
            .filter { $0.date >= cutoff && $0.date <= today && $0.amount > 0 }
        guard let periodStart = days.first?.date, let periodEnd = days.last?.date else { return nil }

        let total = days.reduce(0) { $0 + $1.amount }
        let cost = TokenCost(
            provider: provider,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: total,
            // No session data exists: the provider reports a running total, not
            // a list of sessions. Zero states that plainly.
            sessionCount: 0,
            periodStart: periodStart,
            periodEnd: periodEnd,
            sessionBreakdowns: []
        )

        let daily = days.map { day in
            DailyTokenUsage(
                date: day.date,
                provider: provider,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: day.amount,
                modelBreakdowns: [],
                projectBreakdowns: [],
                sessionBreakdowns: []
            )
        }

        return (cost, daily, [])
    }
}
