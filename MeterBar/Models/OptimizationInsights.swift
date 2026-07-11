import Foundation
import MeterBarShared

// MARK: - Model tier

/// Coarse cost tier for a model, derived from its (possibly raw) id.
///
/// Classification is a pure, name-only heuristic — no network, no prompt
/// contents. New frontier/economy ids are matched by family substring so the
/// tiering keeps working as providers ship dated variants.
nonisolated enum ModelTier: String, Sendable, Equatable {
    case premium
    case standard
    case economy
    case unknown

    static func classify(_ modelName: String) -> ModelTier {
        let name = modelName.lowercased()
        guard !name.isEmpty, !name.contains("unknown") else { return .unknown }

        // Economy markers win first: a "mini"/"haiku" variant of a frontier
        // family is still cheap, so check these before the premium families.
        let economyMarkers = ["haiku", "mini", "nano", "flash", "lite", "small"]
        if economyMarkers.contains(where: name.contains) { return .economy }

        let premiumMarkers = ["opus", "fable", "gpt-5", "gpt5", "o3", "o1"]
        if premiumMarkers.contains(where: name.contains) { return .premium }

        let standardMarkers = ["sonnet", "codex", "gpt-4", "gpt4", "gpt-3"]
        if standardMarkers.contains(where: name.contains) { return .standard }

        return .unknown
    }

    var isPremium: Bool { self == .premium }

    var label: String {
        switch self {
        case .premium: return "Premium"
        case .standard: return "Standard"
        case .economy: return "Economy"
        case .unknown: return "Other"
        }
    }
}

// MARK: - Ranked entry

/// One row of a ranked token breakdown (by model or by usage origin).
nonisolated struct RankedTokenEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let provider: ServiceType
    let totalTokens: Int
    let estimatedCostUSD: Double
    let sessionCount: Int
    /// Share of the ranked group's grand total, 0...1.
    let tokenShare: Double

    var tier: ModelTier { ModelTier.classify(name) }

    var formattedTokens: String { UsageFormat.tokens(totalTokens) }
    var formattedCost: String { UsageFormat.cost(estimatedCostUSD) }
    var formattedShare: String { OptimizationInsights.percentString(tokenShare) }
}

// MARK: - Recommendation

nonisolated enum RecommendationSeverity: Int, Comparable, Sendable {
    case positive = 0
    case info = 1
    case suggestion = 2
    case warning = 3

    static func < (lhs: RecommendationSeverity, rhs: RecommendationSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A single plain-English optimization recommendation. Every field is derived
/// from local aggregates only — never prompt contents.
nonisolated struct OptimizationRecommendation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: RecommendationSeverity
    let systemImage: String
}

// MARK: - Insights

/// Pure, local-only analytics over the cached `CostSummary`.
///
/// **Privacy boundary (hard):** this type reads token totals, model names,
/// origin/workflow metadata, and derived statistics. It never touches prompt
/// contents and nothing here is uploaded — every value is computed on-device
/// from the same cache the Costs page already renders. Kept as a pure model
/// (no SwiftUI, no I/O) so the recommendation logic is unit-testable, matching
/// the `SocialShareCardContent` pattern.
nonisolated struct OptimizationInsights: Equatable, Sendable {
    // MARK: Tunable scoring constants

    private enum Score {
        static let premiumWeight = 0.40
        static let cacheWeight = 0.25
        static let bloatWeight = 0.20
        static let concentrationWeight = 0.15

        /// Input:output ratios at or below this are treated as unbloated.
        static let idealInputOutputRatio = 8.0
        /// Ratio at/above which the context-bloat component bottoms out.
        static let bloatCeilingRatio = 32.0
        /// Origin share at/below which no concentration penalty applies.
        static let concentrationFloor = 0.5
        /// Neutral fill for signals we cannot measure (no output / no cache).
        static let neutralComponent = 0.5
    }

    private enum Threshold {
        static let premiumWarning = 0.5
        static let premiumSuggestion = 0.3
        static let cacheReuseWarning = 0.3
        static let cacheReusePositive = 0.7
        static let inputOutputSuggestion = 20.0
        static let originConcentration = 0.5
        static let trendUpMultiplier = 1.2
    }

    // MARK: KPIs

    let totalTokens: Int
    let periodDays: Int
    let tokens7Day: Int
    let tokens30Day: Int
    let premiumTokenShare: Double
    let inputOutputRatio: Double?
    let cacheReuseRatio: Double?
    let topModels: [RankedTokenEntry]
    let topOrigins: [RankedTokenEntry]
    let optimizationScore: Int
    let recommendations: [OptimizationRecommendation]

    var hasData: Bool { totalTokens > 0 }

    var scoreGrade: String {
        switch optimizationScore {
        case 85...: return "A"
        case 70..<85: return "B"
        case 55..<70: return "C"
        case 40..<55: return "D"
        default: return "F"
        }
    }

    var scoreHeadline: String {
        switch optimizationScore {
        case 85...: return "Lean usage"
        case 70..<85: return "Efficient"
        case 55..<70: return "Room to optimize"
        case 40..<55: return "Heavy usage"
        default: return "Very heavy usage"
        }
    }

    var formattedPremiumShare: String { Self.percentString(premiumTokenShare) }

    var formattedCacheReuse: String {
        guard let cacheReuseRatio else { return "—" }
        return Self.percentString(cacheReuseRatio)
    }

    var formattedInputOutputRatio: String {
        guard let inputOutputRatio else { return "—" }
        return String(format: "%.1f : 1", inputOutputRatio)
    }

    // MARK: Init

    init(summary: CostSummary, now: Date = Date(), calendar: Calendar = .current) {
        let costs = summary.costs

        // Flatten model + origin breakdowns across every provider.
        let modelBreakdowns = costs.flatMap(\.modelBreakdowns)
        let originBreakdowns = costs.flatMap(\.originBreakdowns)

        let modelTokenTotal = modelBreakdowns.reduce(0) { $0 + $1.totalTokens }
        let originTokenTotal = originBreakdowns.reduce(0) { $0 + $1.totalTokens }

        self.topModels = Self.rank(modelBreakdowns, groupTotal: modelTokenTotal)
        self.topOrigins = Self.rank(originBreakdowns, groupTotal: originTokenTotal)

        // Aggregate token buckets across providers.
        let input = costs.reduce(0) { $0 + $1.inputTokens }
        let output = costs.reduce(0) { $0 + $1.outputTokens }
        let cacheCreation = costs.reduce(0) { $0 + $1.cacheCreationTokens }
        let cacheRead = costs.reduce(0) { $0 + $1.cacheReadTokens }

        self.totalTokens = summary.totalTokens
        self.periodDays = summary.periodDays

        self.premiumTokenShare = Self.premiumShare(of: modelBreakdowns, groupTotal: modelTokenTotal)
        self.inputOutputRatio = output > 0 ? Double(input) / Double(output) : nil

        let cacheDenominator = cacheRead + cacheCreation
        self.cacheReuseRatio = cacheDenominator > 0 ? Double(cacheRead) / Double(cacheDenominator) : nil

        self.tokens7Day = Self.windowTokens(summary.dailyUsage, days: 7, now: now, calendar: calendar)
        self.tokens30Day = Self.windowTokens(summary.dailyUsage, days: 30, now: now, calendar: calendar)

        let topOriginShare = topOrigins.first?.tokenShare ?? 0

        self.optimizationScore = Self.computeScore(
            premiumShare: premiumTokenShare,
            inputOutputRatio: inputOutputRatio,
            cacheReuseRatio: cacheReuseRatio,
            topOriginShare: topOriginShare
        )

        if summary.totalTokens > 0 {
            self.recommendations = Self.buildRecommendations(RecommendationInputs(
                premiumShare: premiumTokenShare,
                inputOutputRatio: inputOutputRatio,
                cacheReuseRatio: cacheReuseRatio,
                cacheCreationTokens: cacheCreation,
                topOrigin: topOrigins.first,
                tokens7Day: tokens7Day,
                tokens30Day: tokens30Day
            ))
        } else {
            self.recommendations = []
        }
    }

    // MARK: - Pure computations

    static func premiumShare(of models: [TokenUsageBreakdown], groupTotal: Int? = nil) -> Double {
        let total = groupTotal ?? models.reduce(0) { $0 + $1.totalTokens }
        guard total > 0 else { return 0 }
        let premiumTokens = models
            .filter { ModelTier.classify($0.name).isPremium }
            .reduce(0) { $0 + $1.totalTokens }
        return Double(premiumTokens) / Double(total)
    }

    /// Blends four leanness signals into a 0...100 score (higher = leaner).
    static func computeScore(
        premiumShare: Double,
        inputOutputRatio: Double?,
        cacheReuseRatio: Double?,
        topOriginShare: Double
    ) -> Int {
        let premiumComponent = 1 - clamp01(premiumShare)
        let cacheComponent = cacheReuseRatio.map(clamp01) ?? Score.neutralComponent

        let bloatComponent: Double
        if let ratio = inputOutputRatio {
            let span = Score.bloatCeilingRatio - Score.idealInputOutputRatio
            let excess = (ratio - Score.idealInputOutputRatio) / span
            bloatComponent = 1 - clamp01(excess)
        } else {
            bloatComponent = Score.neutralComponent
        }

        let concentrationSpan = 1 - Score.concentrationFloor
        let concentrationExcess = (clamp01(topOriginShare) - Score.concentrationFloor) / concentrationSpan
        let concentrationComponent = 1 - clamp01(concentrationExcess)

        let weighted =
            Score.premiumWeight * premiumComponent
            + Score.cacheWeight * cacheComponent
            + Score.bloatWeight * bloatComponent
            + Score.concentrationWeight * concentrationComponent

        return Int((clamp01(weighted) * 100).rounded())
    }

    /// Grouped inputs for `buildRecommendations` — keeps the derived signals
    /// together and the function parameter count in check.
    struct RecommendationInputs {
        let premiumShare: Double
        let inputOutputRatio: Double?
        let cacheReuseRatio: Double?
        let cacheCreationTokens: Int
        let topOrigin: RankedTokenEntry?
        let tokens7Day: Int
        let tokens30Day: Int
    }

    static func buildRecommendations(_ inputs: RecommendationInputs) -> [OptimizationRecommendation] {
        let premiumShare = inputs.premiumShare
        let inputOutputRatio = inputs.inputOutputRatio
        let cacheReuseRatio = inputs.cacheReuseRatio
        let cacheCreationTokens = inputs.cacheCreationTokens
        let topOrigin = inputs.topOrigin
        let tokens7Day = inputs.tokens7Day
        let tokens30Day = inputs.tokens30Day

        var recommendations: [OptimizationRecommendation] = []

        // Premium-model routing.
        if premiumShare >= Threshold.premiumWarning {
            recommendations.append(OptimizationRecommendation(
                id: "premium-share",
                title: "Premium models are doing most of the work",
                detail: "Premium models handled \(percentString(premiumShare)) of your tokens. "
                    + "Routing routine edits, summaries, and lookups to a mid-tier or economy model "
                    + "can cut token spend without much quality loss.",
                severity: .warning,
                systemImage: "bolt.badge.automatic"
            ))
        } else if premiumShare >= Threshold.premiumSuggestion {
            recommendations.append(OptimizationRecommendation(
                id: "premium-share",
                title: "Consider tiering your model choice",
                detail: "Premium models handled \(percentString(premiumShare)) of your tokens. "
                    + "Reserve them for the hardest reasoning and let cheaper models handle the rest.",
                severity: .suggestion,
                systemImage: "bolt.badge.automatic"
            ))
        }

        // Cache reuse.
        if let cacheReuseRatio {
            if cacheReuseRatio < Threshold.cacheReuseWarning, cacheCreationTokens > 0 {
                recommendations.append(OptimizationRecommendation(
                    id: "cache-reuse",
                    title: "Cache reuse is low",
                    detail: "Only \(percentString(cacheReuseRatio)) of your cache tokens were reuse — "
                        + "sessions are rebuilding context instead of hitting the cache. Keeping related "
                        + "work in one session and avoiding long idle gaps improves cache hits.",
                    severity: .warning,
                    systemImage: "arrow.triangle.2.circlepath"
                ))
            } else if cacheReuseRatio >= Threshold.cacheReusePositive {
                recommendations.append(OptimizationRecommendation(
                    id: "cache-reuse",
                    title: "Cache reuse looks healthy",
                    detail: "\(percentString(cacheReuseRatio)) of your cache tokens were reuse, "
                        + "so you're paying the cheap cache-read rate instead of rebuilding context.",
                    severity: .positive,
                    systemImage: "checkmark.seal"
                ))
            }
        }

        // Context bloat (input vs output).
        if let inputOutputRatio, inputOutputRatio > Threshold.inputOutputSuggestion {
            recommendations.append(OptimizationRecommendation(
                id: "input-output-ratio",
                title: "Input tokens dwarf output",
                detail: "You're sending roughly \(String(format: "%.0f", inputOutputRatio))× as many input "
                    + "tokens as output. Trimming large pasted context, stale files, or oversized system "
                    + "prompts is usually the fastest token win.",
                severity: .suggestion,
                systemImage: "text.append"
            ))
        }

        // Origin concentration.
        if let topOrigin, topOrigin.tokenShare >= Threshold.originConcentration {
            recommendations.append(OptimizationRecommendation(
                id: "origin-concentration",
                title: "\(topOrigin.name) is your biggest token driver",
                detail: "\(topOrigin.name) accounts for \(percentString(topOrigin.tokenShare)) of tracked "
                    + "tokens. It's the highest-leverage place to tune prompts or model choice.",
                severity: .info,
                systemImage: "chart.pie"
            ))
        }

        // Short-term trend.
        if tokens30Day > 0 {
            let recentDailyRate = Double(tokens7Day) / 7.0
            let monthlyDailyRate = Double(tokens30Day) / 30.0
            if recentDailyRate > monthlyDailyRate * Threshold.trendUpMultiplier {
                recommendations.append(OptimizationRecommendation(
                    id: "trend-up",
                    title: "Token burn is trending up",
                    detail: "Your last 7 days are running hotter than your 30-day average. Worth checking "
                        + "which model or workflow is driving the increase before it compounds.",
                    severity: .info,
                    systemImage: "chart.line.uptrend.xyaxis"
                ))
            }
        }

        // Positive fallback so the panel is never empty on healthy usage.
        if !recommendations.contains(where: { $0.severity >= .suggestion }) {
            recommendations.append(OptimizationRecommendation(
                id: "lean",
                title: "Usage looks lean",
                detail: "No major optimization flags right now — your model mix, cache reuse, and context "
                    + "size are in a healthy range. Keep an eye on premium share as usage grows.",
                severity: .positive,
                systemImage: "leaf"
            ))
        }

        return recommendations.sorted { $0.severity > $1.severity }
    }

    // MARK: - Helpers

    private static func rank(_ breakdowns: [TokenUsageBreakdown], groupTotal: Int) -> [RankedTokenEntry] {
        breakdowns
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
            .map { breakdown in
                RankedTokenEntry(
                    id: breakdown.id,
                    name: breakdown.name,
                    provider: breakdown.provider,
                    totalTokens: breakdown.totalTokens,
                    estimatedCostUSD: breakdown.estimatedCostUSD,
                    sessionCount: breakdown.sessionCount,
                    tokenShare: groupTotal > 0 ? Double(breakdown.totalTokens) / Double(groupTotal) : 0
                )
            }
    }

    private static func windowTokens(
        _ dailyUsage: [DailyTokenUsage],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard days > 0 else { return 0 }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return 0 }
        return dailyUsage
            .filter { usage in
                let day = calendar.startOfDay(for: usage.date)
                return day >= start && day <= today
            }
            .reduce(0) { $0 + $1.totalTokens }
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    static func percentString(_ fraction: Double) -> String {
        "\(Int((clamp01(fraction) * 100).rounded()))%"
    }
}
