import Foundation
import MeterBarShared

/// App-side facts for the providers that share the single-account "simple"
/// refresh path but, unlike Cursor, need no bespoke card layout: one credential,
/// one card, limits mapped onto the shared slots.
extension ServiceType {
    /// In display order. Adding a provider here is what makes the popover and
    /// dashboard build a card for it (`ProviderSnapshotBuilder`).
    static let simpleProviderCases: [ServiceType] = [.kimiCode, .zaiCodingPlan, .githubCopilot]

    /// What the empty card asks for when no credential is readable.
    var simpleProviderSetupPrompt: String {
        switch self {
        case .kimiCode:
            return String(
                localized: "provider.kimi.setup_prompt",
                defaultValue: "Sign in to Kimi Code or add an API key"
            )
        case .zaiCodingPlan:
            return String(
                localized: "provider.zai.setup_prompt",
                defaultValue: "Add your GLM Coding Plan API key"
            )
        case .githubCopilot:
            return String(
                localized: "provider.copilot.setup_prompt",
                defaultValue: "Add a GitHub token and your username"
            )
        case .claudeCode, .codexCli, .cursor, .openRouter, .grok:
            return ""
        }
    }
}
