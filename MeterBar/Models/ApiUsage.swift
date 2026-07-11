import Foundation

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

    var totalTokens: Int { inputTokens + outputTokens }

    var hasData: Bool { totalTokens > 0 }
}

// MARK: - ApiUsagePricing

/// Self-contained per-model pricing for an incomplete API-usage cost estimate
/// (USD per million tokens). Separate from `CostTracker`'s subscription pricing
/// so the two can drift independently; covers Anthropic + OpenAI API models.
///
/// Prices are approximate list rates verified 2026-07-02 — they rot; update
/// against the providers' pricing pages.
nonisolated enum ApiUsagePricing {
    struct Rate {
        let input: Double
        let output: Double
    }

    // Keyed by a normalized model-name fragment (matched as a substring).
    private static let anthropic: [(match: String, rate: Rate)] = [
        ("opus-4", Rate(input: 5.0, output: 25.0)),
        ("opus", Rate(input: 15.0, output: 75.0)),
        ("sonnet", Rate(input: 3.0, output: 15.0)),
        ("haiku-4", Rate(input: 1.0, output: 5.0)),
        ("haiku", Rate(input: 0.25, output: 1.25))
    ]

    private static let openai: [(match: String, rate: Rate)] = [
        ("gpt-4o-mini", Rate(input: 0.15, output: 0.60)),
        ("gpt-4o", Rate(input: 2.50, output: 10.0)),
        ("gpt-4.1-mini", Rate(input: 0.40, output: 1.60)),
        ("gpt-4.1", Rate(input: 2.0, output: 8.0)),
        ("o1-mini", Rate(input: 1.10, output: 4.40)),
        ("o1", Rate(input: 15.0, output: 60.0)),
        ("o3-mini", Rate(input: 1.10, output: 4.40)),
        ("gpt-4-turbo", Rate(input: 10.0, output: 30.0)),
        ("gpt-4", Rate(input: 30.0, output: 60.0)),
        ("gpt-3.5", Rate(input: 0.50, output: 1.50))
    ]

    private static let anthropicDefault = Rate(input: 3.0, output: 15.0)
    private static let openaiDefault = Rate(input: 2.50, output: 10.0)

    static func rate(provider: ApiProvider, model: String?) -> Rate {
        let name = (model ?? "").lowercased()
        switch provider {
        case .anthropic:
            return anthropic.first { name.contains($0.match) }?.rate ?? anthropicDefault
        case .openai:
            return openai.first { name.contains($0.match) }?.rate ?? openaiDefault
        }
    }

    /// Cost in USD for a model's input/output token counts.
    static func cost(provider: ApiProvider, model: String?, inputTokens: Int, outputTokens: Int) -> Double {
        let rate = rate(provider: provider, model: model)
        return Double(inputTokens) / 1_000_000 * rate.input
            + Double(outputTokens) / 1_000_000 * rate.output
    }
}
