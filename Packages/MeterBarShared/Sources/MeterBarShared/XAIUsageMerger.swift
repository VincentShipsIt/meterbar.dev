import Foundation

/// Folds the two data sources behind the single xAI provider into one
/// `UsageMetrics`.
///
/// xAI's tiers share one weekly pool across Grok and Cursor, so the Grok CLI
/// billing read and the Cursor dashboard read often describe the same
/// allowance. The merged card therefore draws one weekly gauge, not two. Legacy
/// Cursor accounts still on monthly pools keep those rows (`additionalLimits`
/// labelled "Cursor Models" / "Other Models") and their on-demand spend.
public enum XAIUsageMerger {
    /// - Parameters:
    ///   - grok: Metrics from the Grok CLI billing source, already `.xai`.
    ///   - cursor: Metrics from the Cursor dashboard source, already `.xai`.
    ///   - stalenessThreshold: Maximum lag behind Cursor before its shared weekly read takes priority.
    /// - Returns: `nil` only when neither source produced metrics. Freshness is the oldest retained quota reading.
    public static func merge(
        grok: UsageMetrics?,
        cursor: UsageMetrics?,
        stalenessThreshold: TimeInterval = ProviderRecommendationPlanner.defaultStalenessThreshold
    ) -> UsageMetrics? {
        guard let grok else { return cursor }
        guard let cursor else { return grok }

        // Grok remains authoritative for polls in the same freshness window.
        // A newer read of the same weekly pool can replace its retained cache,
        // never a legacy monthly pool describing a different allowance. Compare
        // source dates so decoding the same cache stays deterministic.
        let cursorIsNewer = cursor.lastUpdated.timeIntervalSince(grok.lastUpdated) > stalenessThreshold
        let useCursorWeekly = grok.weeklyLimit == nil
            || (grok.weeklyLimit?.periodKind == .weekly && cursor.weeklyLimit?.periodKind == .weekly
                && cursorIsNewer)
        let weeklySource = useCursorWeekly ? cursor : grok
        let weekly = weeklySource.weeklyLimit
        let session = grok.sessionLimit ?? cursor.sessionLimit
        let onDemand = cursor.codeReviewLimit ?? grok.codeReviewLimit

        var additional: [UsageLimit] = []
        // A legacy monthly request quota would otherwise vanish behind Grok's
        // weekly gauge. Pool layouts already list their pools as rows, so only
        // a lone monthly quota is demoted.
        var demoted: [UsageLimit] = []
        if grok.weeklyLimit != nil, let cursorWeekly = cursor.weeklyLimit,
           cursorWeekly.periodKind != .weekly, cursor.additionalLimits.isEmpty {
            demoted = [cursorWeekly]
        }
        for limit in grok.additionalLimits + demoted + cursor.additionalLimits where !additional.contains(limit) {
            additional.append(limit)
        }

        // One snapshot has one freshness date. It cannot be newer than any
        // quota reading it retains; an unrelated successful poll cannot make
        // a cached session, pool, or allowance safe to route over again.
        var observedAt: [Date] = []
        if session != nil { observedAt.append(grok.sessionLimit != nil ? grok.lastUpdated : cursor.lastUpdated) }
        if weekly != nil { observedAt.append(weeklySource.lastUpdated) }
        if onDemand != nil {
            observedAt.append(cursor.codeReviewLimit != nil ? cursor.lastUpdated : grok.lastUpdated)
        }
        if !grok.additionalLimits.isEmpty { observedAt.append(grok.lastUpdated) }
        if !cursor.additionalLimits.isEmpty || !demoted.isEmpty { observedAt.append(cursor.lastUpdated) }

        return UsageMetrics(
            service: .xai,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: onDemand,
            modelLimitLabel: grok.modelLimitLabel ?? cursor.modelLimitLabel,
            extraUsage: grok.extraUsage ?? cursor.extraUsage,
            resetCreditsAvailable: grok.resetCreditsAvailable ?? cursor.resetCreditsAvailable,
            additionalLimits: additional,
            lastUpdated: observedAt.min() ?? max(grok.lastUpdated, cursor.lastUpdated)
        )
    }
}
