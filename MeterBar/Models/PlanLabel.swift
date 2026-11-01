import Foundation
import MeterBarShared

/// The short account-type label a provider card shows beside its name
/// ("Ultra", "Max", "Pro"). Providers report plan tokens in their own
/// shapes, so each is normalised here once and the card only renders the result.
enum PlanLabel {
    /// - Parameters:
    ///   - token: the provider's raw plan token (`subscriptionType`, `plan_type`,
    ///     `membershipType`, Grok tier, Z.ai level).
    ///   - rateLimitTier: Claude's tier token (`default_claude_max_20x`), which
    ///     is what distinguishes Max (5x) from Ultra (20x).
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
            return claudePlan(token: token, rateLimitTier: rateLimitTier)
        case .codexCli:
            return token.lowercased() == "prolite" ? "Pro Lite" : words(token)
        case .museCode:
            let name = words(token).replacingOccurrences(of: "Muse Code ", with: "", options: .anchored)
            return name.hasSuffix(" Usage") ? String(name.dropLast(" Usage".count)) : name
        case .zaiCodingPlan, .openRouter, .kimiCode, .githubCopilot, .claudePlatform:
            return words(token)
        }
    }

    /// OpenRouter has no subscription: every key is prepaid credits, and the one
    /// account-type signal is whether the account has ever bought any.
    static func openRouterTier(isFreeTier: Bool?) -> String? {
        guard let isFreeTier else { return nil }
        return isFreeTier ? "Free" : "Pay as you go"
    }

    /// Claude's consumer plans were renamed in November 2026: the $100 tier
    /// (formerly "Max 5x") is now **Max**, and the $200 tier (formerly
    /// "Max 20x") is now **Ultra**. The OAuth credential still reports both as
    /// `subscriptionType: "max"`, so the multiplier in `rateLimitTier` is what
    /// tells them apart.
    static let claudeUltra = "Ultra"

    /// Whether this plan has no 5-hour session cap. Ultra dropped it, so a
    /// session meter on an Ultra card would be a quota that never binds.
    static func omitsSessionWindow(service: ServiceType, planLabel: String?) -> Bool {
        service == .claudeCode && planLabel == claudeUltra
    }

    private static func claudePlan(token: String, rateLimitTier: String?) -> String {
        let multiplier = claudeMultiplier(from: rateLimitTier)
        switch token.lowercased() {
        case "ultra":
            return claudeUltra
        case "max":
            // Anything above 5x is the top tier; a bare or 5x "max" is Max.
            if let multiplier, let value = Int(multiplier.dropLast()), value > 5 {
                return claudeUltra
            }
            return "Max"
        default:
            let base = words(token)
            guard let multiplier else { return base }
            return "\(base) \(multiplier)"
        }
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
