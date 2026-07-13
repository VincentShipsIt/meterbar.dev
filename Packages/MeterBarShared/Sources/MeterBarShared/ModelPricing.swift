import Foundation

/// API token prices in USD per million tokens.
public struct TokenPricing: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheCreation: Double
    public let cacheRead: Double
    public let cacheCreationOneHour: Double?

    public init(
        input: Double,
        output: Double,
        cacheCreation: Double,
        cacheRead: Double,
        cacheCreationOneHour: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreationOneHour = cacheCreationOneHour
    }
}

/// Single source of truth for the app and CLI's local-log cost estimates.
public enum ModelPricing {
    /// Date these rates were last checked against provider pricing pages.
    public static let revision = "2026-07-02"
    public static let revisionLabel = "Rates verified \(revision)"

    private static let table: [String: TokenPricing] = [
        "claude-sonnet": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-opus": TokenPricing(input: 15.0, output: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-haiku": TokenPricing(input: 0.25, output: 1.25, cacheCreation: 0.30, cacheRead: 0.03),
        "claude-fable-5": TokenPricing(
            input: 10.0, output: 50.0, cacheCreation: 12.5, cacheRead: 1.0, cacheCreationOneHour: 20.0),
        "claude-opus-4-8": TokenPricing(
            input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-7": TokenPricing(
            input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-6": TokenPricing(
            input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-sonnet-4-6": TokenPricing(
            input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4-5": TokenPricing(
            input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4": TokenPricing(
            input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-haiku-4-5": TokenPricing(
            input: 1.0, output: 5.0, cacheCreation: 1.25, cacheRead: 0.10, cacheCreationOneHour: 2.0),
        "codex": TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
        "default": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
    ]

    public static var codex: TokenPricing {
        table["codex"] ?? fallback
    }

    public static func claude(for model: String?) -> TokenPricing {
        guard let model else { return table["claude-sonnet"] ?? fallback }

        let normalized = normalizeClaudeModel(model)
        if let exact = table[normalized] { return exact }
        if normalized.contains("fable") { return table["claude-fable-5"] ?? fallback }
        if normalized.contains("opus") {
            let base = table["claude-opus"] ?? fallback
            if normalized.contains("4-8") { return table["claude-opus-4-8"] ?? base }
            if normalized.contains("4-7") { return table["claude-opus-4-7"] ?? base }
            if normalized.contains("4-6") { return table["claude-opus-4-6"] ?? base }
            return base
        }
        if normalized.contains("haiku") {
            return normalized.contains("4-5")
                ? table["claude-haiku-4-5"] ?? (table["claude-haiku"] ?? fallback)
                : table["claude-haiku"] ?? fallback
        }
        if normalized.contains("sonnet") {
            let base = table["claude-sonnet"] ?? fallback
            if normalized.contains("4-6") { return table["claude-sonnet-4-6"] ?? base }
            if normalized.contains("4-5") { return table["claude-sonnet-4-5"] ?? base }
            if normalized.contains("4") { return table["claude-sonnet-4"] ?? base }
            return base
        }
        return fallback
    }

    public static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }
        if let lastDot = trimmed.lastIndex(of: "."), trimmed.contains("claude-") {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { trimmed = tail }
        }
        if let versionRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(versionRange)
        }
        if let dateRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(trimmed[..<dateRange.lowerBound])
        }
        return trimmed
    }

    private static let fallback = TokenPricing(
        input: 3.0,
        output: 15.0,
        cacheCreation: 3.75,
        cacheRead: 0.30
    )
}
