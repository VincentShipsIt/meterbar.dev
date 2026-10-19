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
    /// - Returns: `nil` only when neither source produced metrics.
    public static func merge(grok: UsageMetrics?, cursor: UsageMetrics?) -> UsageMetrics? {
        guard let grok else { return cursor }
        guard let cursor else { return grok }

        // Grok's billing read is authoritative for the shared pool; Cursor
        // fills a window only when Grok reported nothing for it.
        let weekly = grok.weeklyLimit ?? cursor.weeklyLimit
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

        return UsageMetrics(
            service: .xai,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: onDemand,
            modelLimitLabel: grok.modelLimitLabel ?? cursor.modelLimitLabel,
            extraUsage: grok.extraUsage ?? cursor.extraUsage,
            resetCreditsAvailable: grok.resetCreditsAvailable ?? cursor.resetCreditsAvailable,
            additionalLimits: additional,
            lastUpdated: max(grok.lastUpdated, cursor.lastUpdated)
        )
    }
}
