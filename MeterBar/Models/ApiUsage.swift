import Foundation
import MeterBarShared

// MARK: - ApiProvider

/// A pay-as-you-go API account whose *organization usage* MeterBar reports,
/// distinct from the flat-rate subscription providers (`ServiceType`). These
/// have no quota/reset — only spend and tokens over a chosen window.
nonisolated enum ApiProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI API"
        }
    }

    /// Keychain account key for this provider's org admin key.
    var keychainKey: String {
        switch self {
        case .anthropic: return "claude_admin_key"
        case .openai: return "openai_admin_key"
        }
    }
}

// MARK: - ApiUsageWindow

/// The reporting window for an API-usage card. `custom` carries an explicit
/// day range the user picked.
nonisolated enum ApiUsageWindow: Equatable, Sendable {
    case last7Days
    case last30Days
    case custom(start: Date, end: Date)

    var label: String {
        switch self {
        case .last7Days: return "7 days"
        case .last30Days: return "30 days"
        case .custom: return "Custom"
        }
    }

    /// Resolved `[start, end)` for the provider endpoints. Presets end at
    /// `now`; custom date-only selections include the full final day by using
    /// the start of the following day as their exclusive endpoint.
    func dateRange(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch self {
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: now) ?? now, now)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now) ?? now, now)
        case let .custom(start, end):
            let firstDay = calendar.startOfDay(for: min(start, end))
            let lastDay = calendar.startOfDay(for: max(start, end))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            return (firstDay, exclusiveEnd)
        }
    }
}

// MARK: - ApiModelUsage

nonisolated struct ApiModelUsage: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCostUSD: Double
    /// `model` matched no known rate-table entry, so `estimatedCostUSD` above
    /// used a provider default rate rather than a verified one (#537).
    ///
    /// `var` with a default rather than `let`, purely so existing fixtures
    /// that construct `ApiModelUsage` without naming this field keep
    /// compiling — Swift only extends a memberwise-init default to callers
    /// when the property is mutable.
    var isPricingUnverified = false
    /// At least one usage row for this model carried none of its input-token
    /// fields — e.g. a provider renamed or relocated them — rather than
    /// legitimately reporting zero. `inputTokens` above is undercounted for
    /// that row; distinguishing this from a genuine zero is the point (#537).
    var hasIncompleteInputData = false

    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - ApiUsage

/// Aggregated organization API usage for one provider over one window.
nonisolated struct ApiUsage: Sendable {
    let provider: ApiProvider
    let windowStart: Date
    let windowEnd: Date
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCostUSD: Double
    /// Per-model breakdown, highest spend first.
    let models: [ApiModelUsage]
    /// The org's usage paginated past `ApiUsageService`'s safety cap while the
    /// provider still reported more pages (`has_more: true`) — the totals
    /// above are a partial sum over the fetched pages, not the window's
    /// actual total (#537). `var` for the same memberwise-init-default reason
    /// as `ApiModelUsage`'s markers above.
    var isTruncated = false

    var totalTokens: Int { inputTokens + outputTokens }

    var hasData: Bool { totalTokens > 0 }

    /// Any model's cost used a default rate rather than a matched one.
    var hasUnverifiedPricing: Bool { models.contains { $0.isPricingUnverified } }

    /// Any model had at least one usage row with no input-token fields at all.
    var hasIncompleteInputData: Bool { models.contains { $0.hasIncompleteInputData } }
}

// MARK: - ApiUsagePricing

/// Self-contained per-model pricing for an incomplete API-usage cost estimate
/// (USD per million tokens). Separate from `CostTracker`'s subscription pricing
/// so the two can drift independently; covers Anthropic + OpenAI API models.
///
/// Both providers resolve through `MeterBarShared.ModelPricing` — the same
/// dated, cache-aware schedule the Costs page uses — rather than a local
/// table, so cache-read and cache-creation tokens are never billed at the
/// uncached input rate (#537), and a model name is only ever matched exactly
/// or most-specific-first, never by an ambiguous substring the way the old
/// linear tables did (#537, #554).
nonisolated enum ApiUsagePricing {
    /// A model's usage split into the components each carries its own rate,
    /// mirroring `TokenPricing`'s tiers so no component is ever folded into
    /// another's rate.
    struct TokenBreakdown: Sendable {
        var uncachedInput = 0
        var cacheRead = 0
        var cacheCreationFiveMinute = 0
        var cacheCreationOneHour = 0
        var output = 0
    }

    /// Anthropic model families `ModelPricing` prices explicitly. A model
    /// matching none of these took `ModelPricing`'s undated "default" rate —
    /// the unverified-pricing signal, since `ModelPricing` itself does not
    /// expose which key it resolved to.
    private static let knownAnthropicFamilies = ["fable", "opus", "haiku", "sonnet"]

    /// `model` matched no known rate-table entry for `provider`, so its cost
    /// used a default rate rather than a verified one.
    static func isPricingUnverified(provider: ApiProvider, model: String?) -> Bool {
        switch provider {
        case .anthropic:
            let name = (model ?? "").lowercased()
            return !knownAnthropicFamilies.contains { name.contains($0) }
        case .openai:
            return !ModelPricing.isKnownOpenAIModel(model)
        }
    }

    /// Cost in USD for a model's input/output token counts, with no cache
    /// breakdown — for callers that only distinguish input from output.
    static func cost(provider: ApiProvider, model: String?, inputTokens: Int, outputTokens: Int) -> Double {
        cost(provider: provider, model: model, tokens: TokenBreakdown(uncachedInput: inputTokens, output: outputTokens))
    }

    /// Cost in USD for a model's full cache-aware token breakdown. Runs
    /// through `TokenCostMath` — the same formula the Costs page uses — so a
    /// cache-read token is never billed at the uncached input rate (#537).
    static func cost(
        provider: ApiProvider,
        model: String?,
        tokens: TokenBreakdown,
        at timestamp: Date = Date()
    ) -> Double {
        switch provider {
        case .anthropic:
            let pricing = ModelPricing.claude(for: model, at: timestamp)
            return TokenCostMath.calculateClaudeCost(
                input: tokens.uncachedInput,
                output: tokens.output,
                cacheCreation: tokens.cacheCreationFiveMinute + tokens.cacheCreationOneHour,
                cacheCreationOneHour: tokens.cacheCreationOneHour,
                cacheRead: tokens.cacheRead,
                pricing: pricing
            )
        case .openai:
            let pricing = ModelPricing.openAI(for: model, at: timestamp)
            return TokenCostMath.calculateCost(
                input: tokens.uncachedInput,
                output: tokens.output,
                cacheCreation: 0,
                cacheRead: tokens.cacheRead,
                pricing: pricing
            )
        }
    }
}
