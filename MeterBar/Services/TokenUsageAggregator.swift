import Foundation
import MeterBarShared

/// Folds the per-bucket `TokenAccumulator` totals a scan produces into the
/// daily-usage rows and breakdown rows the UI renders.
/// Split out of `CostTracker` (audit C1d).
enum TokenUsageAggregator {
    nonisolated static func makeHourlyUsage(
        from hourlyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing,
        pricingAt: ((Date) -> TokenPricing)? = nil
    ) -> [HourlyTokenUsage] {
        hourlyTotals.map { hour, tokens in
            let rowPricing = pricingAt?(hour) ?? pricing
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
            return HourlyTokenUsage(
                date: hour,
                provider: provider,
                inputTokens: billableInput,
                outputTokens: output,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost
            )
        }
    }

    /// `pricingAt` resolves one row's rate from its model name (`nil` for the
    /// day's own flat total) and the day it was recorded, so a dated schedule
    /// prices history at the rate that was in effect then instead of today's
    /// (issue #339). Without it every row falls back to `pricing`.
    nonisolated static func makeDailyUsage(
        from dailyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing,
        modelsByDay: [Date: [String: TokenAccumulator]] = [:],
        projectsByDay: [Date: [String: TokenAccumulator]] = [:],
        projectModelsByDay: [Date: [String: [String: TokenAccumulator]]] = [:],
        projectSessionsByDay: [Date: [String: [String: TokenAccumulator]]] = [:],
        projectSessionModelsByDay: [Date: [String: [String: [String: TokenAccumulator]]]] = [:],
        pricingAt: ((String?, Date) -> TokenPricing)? = nil
    ) -> [DailyTokenUsage] {
        dailyTotals.map { day, tokens in
            let dayPricing = pricingAt?(nil, day) ?? pricing
            let pricingForName = pricingAt.map { resolve in { (name: String) in resolve(name, day) } }
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : TokenCostMath.calculateCost(
                    input: billableInput,
                    output: tokens.output + tokens.reasoning,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: dayPricing
                )
            let projectRows = projectsByDay[day].map {
                makeProjectBreakdowns(
                    from: $0,
                    modelsByProject: projectModelsByDay[day] ?? [:],
                    sessionsByProject: projectSessionsByDay[day] ?? [:],
                    sessionModelsByProject: projectSessionModelsByDay[day] ?? [:],
                    provider: provider,
                    pricing: dayPricing,
                    pricingForName: pricingForName
                )
            }
            return DailyTokenUsage(
                date: day,
                provider: provider,
                inputTokens: billableInput,
                outputTokens: tokens.output + tokens.reasoning,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost,
                modelBreakdowns: modelsByDay[day].map {
                    makeBreakdowns(
                        from: $0,
                        provider: provider,
                        pricing: dayPricing,
                        pricingForName: pricingForName
                    )
                },
                projectBreakdowns: projectRows,
                sessionBreakdowns: projectSessionsByDay[day].map {
                    makeSessionBreakdowns(
                        from: flattenSessions($0),
                        modelsBySession: flattenSessionModels(projectSessionModelsByDay[day] ?? [:]),
                        provider: provider,
                        pricing: dayPricing,
                        pricingForName: pricingForName
                    )
                }
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

    /// Per-project rollup rows, each carrying its own nested per-model
    /// breakdown (issue #270's "rollup view plus drill-down to model
    /// breakdown"). Reuses `makeBreakdowns` twice — once for the top-level
    /// rollup, once per project for its `modelBreakdowns` slice — rather than
    /// inventing a second aggregation algorithm.
    nonisolated static func makeProjectBreakdowns(
        from projectTotals: [String: TokenAccumulator],
        modelsByProject: [String: [String: TokenAccumulator]],
        sessionsByProject: [String: [String: TokenAccumulator]] = [:],
        sessionModelsByProject: [String: [String: [String: TokenAccumulator]]] = [:],
        provider: ServiceType,
        pricing: TokenPricing,
        pricingForName: ((String) -> TokenPricing)? = nil
    ) -> [TokenUsageBreakdown] {
        makeBreakdowns(from: projectTotals, provider: provider, pricing: pricing).map { row in
            TokenUsageBreakdown(
                provider: row.provider,
                name: row.name,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheCreationTokens: row.cacheCreationTokens,
                cacheReadTokens: row.cacheReadTokens,
                estimatedCostUSD: row.estimatedCostUSD,
                sessionCount: row.sessionCount,
                modelBreakdowns: modelsByProject[row.name].map {
                    makeBreakdowns(from: $0, provider: provider, pricing: pricing, pricingForName: pricingForName)
                } ?? [],
                sessionBreakdowns: makeSessionBreakdowns(
                    from: sessionsByProject[row.name] ?? [:],
                    modelsBySession: sessionModelsByProject[row.name] ?? [:],
                    provider: provider,
                    pricing: pricing,
                    pricingForName: pricingForName
                )
            )
        }
    }

    /// Per-session rows, each carrying its own nested per-model slice (issue #391).
    nonisolated static func makeSessionBreakdowns(
        from sessionTotals: [String: TokenAccumulator],
        modelsBySession: [String: [String: TokenAccumulator]],
        provider: ServiceType,
        pricing: TokenPricing,
        pricingForName: ((String) -> TokenPricing)? = nil
    ) -> [TokenUsageBreakdown] {
        makeBreakdowns(from: sessionTotals, provider: provider, pricing: pricing).map { row in
            TokenUsageBreakdown(
                provider: row.provider,
                name: row.name,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheCreationTokens: row.cacheCreationTokens,
                cacheReadTokens: row.cacheReadTokens,
                estimatedCostUSD: row.estimatedCostUSD,
                sessionCount: row.sessionCount,
                modelBreakdowns: modelsBySession[row.name].map {
                    makeBreakdowns(from: $0, provider: provider, pricing: pricing, pricingForName: pricingForName)
                } ?? []
            )
        }
    }

    /// Session ids are only unique inside their own project, so flattening the
    /// nested map by raw id merged two unrelated conversations into one row —
    /// and always merged every project's `unknown` fallback bucket. Ids that
    /// stay unambiguous keep the bare conversation id consumers index on; the
    /// rest are qualified as `"<project>/<session>"`.
    nonisolated static func flattenSessions(
        _ projectSessions: [String: [String: TokenAccumulator]]
    ) -> [String: TokenAccumulator] {
        var flattened: [String: TokenAccumulator] = [:]
        let ambiguous = ambiguousSessionIDs(in: projectSessions)
        for (project, sessions) in projectSessions {
            CostScanNestedMerge.accumulators(
                &flattened,
                qualifyKeys(sessions, project: project, ambiguous: ambiguous)
            )
        }
        return flattened
    }

    /// Qualified in lockstep with `flattenSessions`: `makeSessionBreakdowns`
    /// looks each row's model slice up by the session row's own name.
    nonisolated static func flattenSessionModels(
        _ projectSessionModels: [String: [String: [String: TokenAccumulator]]]
    ) -> [String: [String: TokenAccumulator]] {
        var flattened: [String: [String: TokenAccumulator]] = [:]
        let ambiguous = ambiguousSessionIDs(in: projectSessionModels)
        for (project, sessions) in projectSessionModels {
            CostScanNestedMerge.keyedAccumulators(
                &flattened,
                qualifyKeys(sessions, project: project, ambiguous: ambiguous)
            )
        }
        return flattened
    }

    /// Ids that cannot stand alone in a flattened map: the `unknown` fallback
    /// (never an identity, and qualifying it unconditionally keeps the key
    /// stable across days rather than only on days two projects both fall back)
    /// plus any id recorded under more than one project.
    nonisolated private static func ambiguousSessionIDs<Value>(
        in projectSessions: [String: [String: Value]]
    ) -> Set<String> {
        var seen: Set<String> = []
        var ambiguous: Set<String> = [CostSessionAttribution.unknownSessionID]
        for (_, sessions) in projectSessions {
            for id in sessions.keys where !seen.insert(id).inserted {
                ambiguous.insert(id)
            }
        }
        return ambiguous
    }

    nonisolated private static func qualifyKeys<Value>(
        _ sessions: [String: Value],
        project: String,
        ambiguous: Set<String>
    ) -> [String: Value] {
        guard sessions.keys.contains(where: ambiguous.contains) else { return sessions }
        return Dictionary(
            uniqueKeysWithValues: sessions.map { id, value in
                (ambiguous.contains(id) ? "\(project)/\(id)" : id, value)
            }
        )
    }
}
