import Foundation
import MeterBarShared

/// The short account-type label a provider card shows beside its name
/// ("Max 20x", "Pro", "Ultra"). Providers report plan tokens in their own
/// shapes, so each is normalised here once and the card only renders the result.
enum PlanLabel {
    /// - Parameters:
    ///   - token: the provider's raw plan token (`subscriptionType`, `plan_type`,
    ///     `membershipType`, Grok tier, Z.ai level).
    ///   - rateLimitTier: Claude's tier token (`default_claude_max_20x`), which
    ///     is what distinguishes Max 5x from Max 20x.
    static func make(service: ServiceType, token: String?, rateLimitTier: String? = nil) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        switch service {
        case .xai:
            // Grok reports a human-facing tier ("SuperGrok"); Cursor reports a
            // lowercase membership token ("ultra") that needs normalising.
            return token == token.lowercased() ? words(token) : token
        case .claudeCode:
            let base = words(token)
            guard let multiplier = claudeMultiplier(from: rateLimitTier) else { return base }
            return "\(base) \(multiplier)"
        case .codexCli:
            return token.lowercased() == "prolite" ? "Pro Lite" : words(token)
        case .zaiCodingPlan, .openRouter, .kimiCode, .githubCopilot, .museCode, .claudePlatform:
            return words(token)
        }
    }

    /// OpenRouter has no subscription: every key is prepaid credits, and the one
    /// account-type signal is whether the account has ever bought any.
    static func openRouterTier(isFreeTier: Bool?) -> String? {
        guard let isFreeTier else { return nil }
        return isFreeTier ? "Free" : "Pay as you go"
    }

    private static func words(_ token: String) -> String {
        token
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// `default_claude_max_20x` → `20x`; tiers with no multiplier return nil.
    private static func claudeMultiplier(from tier: String?) -> String? {
        guard let tier else { return nil }
        return tier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.lowercased() }
            .first { part in
                part.hasSuffix("x") && Int(part.dropLast()) != nil
            }
    }
}
