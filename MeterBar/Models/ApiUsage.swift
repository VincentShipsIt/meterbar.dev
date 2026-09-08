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
/// Anthropic rates are resolved through `MeterBarShared.ModelPricing` — the
/// same dated, cache-aware schedule the Costs page uses — rather than a
/// second table here, so cache-read and cache-creation tokens are never
/// billed at the uncached input rate (#537) and an opus-4-shaped substring
/// can never shadow a more specific entry the way the old linear table did.
///
/// OpenAI's admin usage API reports models `ModelPricing` does not carry
/// (`gpt-4o`, `o1`, …), so those rates stay local. That table's cache-read
/// column is a 50% "cached input" discount applied uniformly — the industry
/// convention across the GPT-4 family — not a per-model verified figure like
/// the Anthropic schedule; see the consolidation follow-up filed with #537.
///
/// Prices are approximate list rates verified 2026-07-02 — they rot; update
/// against the providers' pricing pages.
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

    private struct OpenAIRate {
        let input: Double
        let output: Double
        let cacheRead: Double
    }

    // Keyed by a normalized model-name fragment (matched as a substring, most
    // specific first).
    private static let openai: [(match: String, rate: OpenAIRate)] = [
        ("gpt-4o-mini", OpenAIRate(input: 0.15, output: 0.60, cacheRead: 0.075)),
        ("gpt-4o", OpenAIRate(input: 2.50, output: 10.0, cacheRead: 1.25)),
        ("gpt-4.1-mini", OpenAIRate(input: 0.40, output: 1.60, cacheRead: 0.20)),
        ("gpt-4.1", OpenAIRate(input: 2.0, output: 8.0, cacheRead: 1.0)),
        ("o1-mini", OpenAIRate(input: 1.10, output: 4.40, cacheRead: 0.55)),
        ("o1", OpenAIRate(input: 15.0, output: 60.0, cacheRead: 7.5)),
        ("o3-mini", OpenAIRate(input: 1.10, output: 4.40, cacheRead: 0.55)),
        ("gpt-4-turbo", OpenAIRate(input: 10.0, output: 30.0, cacheRead: 5.0)),
        ("gpt-4", OpenAIRate(input: 30.0, output: 60.0, cacheRead: 15.0)),
        ("gpt-3.5", OpenAIRate(input: 0.50, output: 1.50, cacheRead: 0.25))
    ]

    private static let openaiDefault = OpenAIRate(input: 2.50, output: 10.0, cacheRead: 1.25)

    /// Anthropic model families `ModelPricing` prices explicitly. A model
    /// matching none of these took `ModelPricing`'s undated "default" rate —
    /// the unverified-pricing signal, since `ModelPricing` itself does not
    /// expose which key it resolved to.
    private static let knownAnthropicFamilies = ["fable", "opus", "haiku", "sonnet"]

    /// `model` matched no known rate-table entry for `provider`, so its cost
    /// used a default rate rather than a verified one.
    static func isPricingUnverified(provider: ApiProvider, model: String?) -> Bool {
        let name = (model ?? "").lowercased()
        switch provider {
        case .anthropic:
            return !knownAnthropicFamilies.contains { name.contains($0) }
        case .openai:
            return !openai.contains { name.contains($0.match) }
        }
    }

    private static func openAIPricing(for model: String?) -> TokenPricing {
        let name = (model ?? "").lowercased()
        let rate = openai.first { name.contains($0.match) }?.rate ?? openaiDefault
        // OpenAI's usage API has no cache-write charge, unlike Anthropic's.
        return TokenPricing(input: rate.input, output: rate.output, cacheCreation: 0, cacheRead: rate.cacheRead)
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
            return TokenCostMath.calculateCost(
                input: tokens.uncachedInput,
                output: tokens.output,
                cacheCreation: 0,
                cacheRead: tokens.cacheRead,
                pricing: openAIPricing(for: model)
            )
        }
    }
}
