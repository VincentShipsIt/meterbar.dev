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

        let premiumMarkers = ["opus", "fable", "gpt-6", "gpt6", "gpt-5", "gpt5", "o3", "o1"]
        if premiumMarkers.contains(where: name.contains) { return .premium }

        // Grok's coding models bill at $2/$6 per million, which is Sonnet's
        // class rather than Opus's, so the whole family reads as mid-cost.
        let standardMarkers = ["sonnet", "codex", "grok", "gpt-4", "gpt4", "gpt-3"]
        if standardMarkers.contains(where: name.contains) { return .standard }

        return .unknown
    }

    var isPremium: Bool { self == .premium }

    /// Compact relative-price marker used by the Optimize breakdown. The tier
    /// is intentionally typography-only: status colors stay reserved for
    /// health and attention states elsewhere in the app.
    var costIndicator: String {
        switch self {
        case .premium: return "$$$"
        case .standard: return "$$"
        case .economy: return "$"
        case .unknown: return "—"
        }
    }

    var costAccessibilityLabel: String {
        switch self {
        case .premium:
            return String(
                localized: "optimize.cost_tier.high",
                defaultValue: "High-cost model",
                comment: "VoiceOver description for a three-dollar-sign model cost marker."
            )
        case .standard:
            return String(
                localized: "optimize.cost_tier.mid",
                defaultValue: "Mid-cost model",
                comment: "VoiceOver description for a two-dollar-sign model cost marker."
            )
        case .economy:
            return String(
                localized: "optimize.cost_tier.low",
                defaultValue: "Low-cost model",
                comment: "VoiceOver description for a one-dollar-sign model cost marker."
            )
        case .unknown:
            return String(
                localized: "optimize.cost_tier.unknown",
                defaultValue: "Unknown cost tier",
                comment: "VoiceOver description when a model cost tier cannot be classified."
            )
        }
    }

    private var pluralCostAccessibilityLabel: String {
        switch self {
        case .premium:
            return String(
                localized: "optimize.cost_tier.high_plural",
                defaultValue: "High-cost models",
                comment: "VoiceOver description replacing a three-dollar-sign marker before the plural word models."
            )
        case .standard:
            return String(
                localized: "optimize.cost_tier.mid_plural",
                defaultValue: "Mid-cost models",
                comment: "VoiceOver description replacing a two-dollar-sign marker before the plural word models."
            )
        case .economy:
            return String(
                localized: "optimize.cost_tier.low_plural",
                defaultValue: "Low-cost models",
                comment: "VoiceOver description replacing a one-dollar-sign marker before the plural word models."
            )
        case .unknown:
            return costAccessibilityLabel
        }
    }

    /// Replaces the visual relative-price scale with semantic speech while
    /// leaving the on-screen recommendation copy untouched. Longest markers
    /// go first so `$$$` can never be mistaken for three low-cost markers.
    static func accessibilityText(replacingCostMarkersIn text: String) -> String {
        [ModelTier.premium, .standard, .economy].reduce(text) { result, tier in
            result
                .replacingOccurrences(
                    of: "\(tier.costIndicator) models",
                    with: tier.pluralCostAccessibilityLabel
                )
                .replacingOccurrences(
                    of: "\(tier.costIndicator) model",
                    with: tier.costAccessibilityLabel
                )
                .replacingOccurrences(of: tier.costIndicator, with: tier.costAccessibilityLabel)
        }
    }
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
    /// The numbers the recommendation was derived from ("62% · 3.0M of 4.4M
    /// tokens"), so it can be checked rather than taken on faith. `nil` only
    /// for the "usage looks lean" fallback, which is the absence of a signal.
    var source: String?

    init(
        id: String,
        title: String,
        detail: String,
        severity: RecommendationSeverity,
        systemImage: String,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.systemImage = systemImage
        self.source = source
    }

    var accessibilityDetail: String {
        ModelTier.accessibilityText(replacingCostMarkersIn: detail)
    }
}

// MARK: - Insights

/// Pure, local-only recommendations over one reporting window.
///
/// **Privacy boundary (hard):** this type reads token totals, model names,
/// origin/workflow metadata, and derived statistics. It never touches prompt
/// contents and nothing here is uploaded — every value is computed on-device
/// from the same cache the Usage page already renders. Kept as a pure model
/// (no SwiftUI, no I/O) so the recommendation logic is unit-testable, matching
/// the `SocialShareCardContent` pattern.
///
/// It is built from a `UsageReport`, which has already cut every figure to the
/// selected window; this type only decides what the figures mean. There is no
/// blended score or letter grade — it was a weighted average of four heuristics
/// and hid which one moved. Each signal stands as its own row instead.
nonisolated struct OptimizationInsights: Equatable, Sendable {
    private enum Threshold {
        static let premiumWarning = 0.5
        static let premiumSuggestion = 0.3
        static let cacheReuseWarning = 0.3
        static let cacheReusePositive = 0.7
        static let inputOutputSuggestion = 20.0
        static let originConcentration = 0.5
        static let trendUpMultiplier = 1.2
    }

    /// Cache reads and writes from the providers that report both. Codex and
    /// Grok log reads but never writes, so folding them in would push the
    /// ratio toward 100% whatever the real behavior was.
    struct CacheUse: Equatable, Sendable {
        let readTokens: Double
        let writeTokens: Double

        var reuseRatio: Double? {
            let denominator = readTokens + writeTokens
            return denominator > 0 ? readTokens / denominator : nil
        }
    }

    struct OriginShare: Equatable, Sendable {
        let name: String
        let tokens: Double
        let groupTokens: Double

        var share: Double { groupTokens > 0 ? tokens / groupTokens : 0 }
    }

    struct Trend: Equatable, Sendable {
        let recentDailyTokens: Double
        let windowDailyTokens: Double
        let recentDays: Int
    }

    /// Everything the recommendation rules read, already windowed.
    struct Inputs: Equatable, Sendable {
        var premiumTokens: Double = 0
        var attributedModelTokens: Double = 0
        var inputTokens: Double = 0
        var outputTokens: Double = 0
        var cacheUse: CacheUse?
        var topOrigin: OriginShare?
        var trend: Trend?
    }

    let inputs: Inputs
    let recommendations: [OptimizationRecommendation]

    /// Premium-tier share of the tokens whose model is known. `nil` when no
    /// token in the window carries model attribution.
    var premiumTokenShare: Double? {
        inputs.attributedModelTokens > 0 ? inputs.premiumTokens / inputs.attributedModelTokens : nil
    }

    var inputOutputRatio: Double? {
        inputs.outputTokens > 0 ? inputs.inputTokens / inputs.outputTokens : nil
    }

    var cacheReuseRatio: Double? { inputs.cacheUse?.reuseRatio }

    var formattedPremiumShare: String {
        premiumTokenShare.map(Self.percentString) ?? "—"
    }

    var formattedCacheReuse: String {
        cacheReuseRatio.map(Self.percentString) ?? "—"
    }

    var formattedInputOutputRatio: String {
        guard let inputOutputRatio else { return "—" }
        return String(format: "%.1f : 1", inputOutputRatio)
    }

    init(inputs: Inputs, hasData: Bool = true) {
        self.inputs = inputs
        recommendations = hasData ? Self.buildRecommendations(inputs) : []
    }

    // MARK: - Recommendations

    private static func buildRecommendations(_ inputs: Inputs) -> [OptimizationRecommendation] {
        var recommendations: [OptimizationRecommendation] = []
        let format = UsageFormat.compactTokens

        if inputs.attributedModelTokens > 0 {
            let premiumShare = inputs.premiumTokens / inputs.attributedModelTokens
            let source = "\(percentString(premiumShare)) · \(format(inputs.premiumTokens)) of "
                + "\(format(inputs.attributedModelTokens)) tokens"
            if premiumShare >= Threshold.premiumWarning {
                recommendations.append(OptimizationRecommendation(
                    id: "premium-share",
                    title: "High-cost models are doing most of the work",
                    detail: "$$$ models handled \(percentString(premiumShare)) of your tokens. "
                        + "Routing routine edits, summaries, and lookups to $$ or $ models "
                        + "can cut token spend without much quality loss.",
                    severity: .warning,
                    systemImage: "bolt.badge.automatic",
                    source: source
                ))
            } else if premiumShare >= Threshold.premiumSuggestion {
                recommendations.append(OptimizationRecommendation(
                    id: "premium-share",
                    title: "Use lower-cost models more often",
                    detail: "$$$ models handled \(percentString(premiumShare)) of your tokens. "
                        + "Reserve them for the hardest reasoning and route routine work to $$ or $ models.",
                    severity: .suggestion,
                    systemImage: "bolt.badge.automatic",
                    source: source
                ))
            }
        }

        if let cacheUse = inputs.cacheUse, let ratio = cacheUse.reuseRatio {
            let source = "\(format(cacheUse.readTokens)) read · \(format(cacheUse.writeTokens)) written"
            if ratio < Threshold.cacheReuseWarning, cacheUse.writeTokens > 0 {
                recommendations.append(OptimizationRecommendation(
                    id: "cache-reuse",
                    title: "Cache reuse is low",
                    detail: "Only \(percentString(ratio)) of your cache tokens were reuse — "
                        + "sessions are rebuilding context instead of hitting the cache. Keeping related "
                        + "work in one session and avoiding long idle gaps improves cache hits.",
                    severity: .warning,
                    systemImage: "arrow.triangle.2.circlepath",
                    source: source
                ))
            } else if ratio >= Threshold.cacheReusePositive {
                recommendations.append(OptimizationRecommendation(
                    id: "cache-reuse",
                    title: "Cache reuse looks healthy",
                    detail: "\(percentString(ratio)) of your cache tokens were reuse, "
                        + "so you're paying the cheap cache-read rate instead of rebuilding context.",
                    severity: .positive,
                    systemImage: "checkmark.seal",
                    source: source
                ))
            }
        }

        if inputs.outputTokens > 0 {
            let ratio = inputs.inputTokens / inputs.outputTokens
            if ratio > Threshold.inputOutputSuggestion {
                recommendations.append(OptimizationRecommendation(
                    id: "input-output-ratio",
                    title: "Input tokens dwarf output",
                    detail: "You're sending roughly \(String(format: "%.0f", ratio))× as many input "
                        + "tokens as output. Trimming large pasted context, stale files, or oversized system "
                        + "prompts is usually the fastest token win.",
                    severity: .suggestion,
                    systemImage: "text.append",
                    source: "\(format(inputs.inputTokens)) input · \(format(inputs.outputTokens)) output"
                ))
            }
        }

        if let origin = inputs.topOrigin, origin.share >= Threshold.originConcentration {
            recommendations.append(OptimizationRecommendation(
                id: "origin-concentration",
                title: "\(origin.name) is your biggest token driver",
                detail: "\(origin.name) accounts for \(percentString(origin.share)) of tracked "
                    + "tokens. It's the highest-leverage place to tune prompts or model choice.",
                severity: .info,
                systemImage: "chart.pie",
                source: "\(format(origin.tokens)) of \(format(origin.groupTokens)) tokens"
            ))
        }

        if let trend = inputs.trend,
           trend.recentDailyTokens > trend.windowDailyTokens * Threshold.trendUpMultiplier {
            recommendations.append(OptimizationRecommendation(
                id: "trend-up",
                title: "Token burn is trending up",
                detail: "Your last \(trend.recentDays) days are running hotter than the rest of this window. "
                    + "Worth checking which model or workflow is driving the increase before it compounds.",
                severity: .info,
                systemImage: "chart.line.uptrend.xyaxis",
                source: "\(format(trend.recentDailyTokens))/day recently · "
                    + "\(format(trend.windowDailyTokens))/day over the window"
            ))
        }

        // Positive fallback so the column is never empty on healthy usage.
        if !recommendations.contains(where: { $0.severity >= .suggestion }) {
            recommendations.append(OptimizationRecommendation(
                id: "lean",
                title: "Usage looks lean",
                detail: "No major optimization flags right now — your model mix, cache reuse, and context "
                    + "size are in a healthy range. Keep an eye on $$$ model share as usage grows.",
                severity: .positive,
                systemImage: "leaf"
            ))
        }

        return recommendations.sorted { $0.severity > $1.severity }
    }

    // MARK: - Helpers

    static func percentString(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}
