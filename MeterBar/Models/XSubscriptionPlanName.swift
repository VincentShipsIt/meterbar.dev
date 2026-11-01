import Foundation

/// The current X Subscription name for an xAI plan token.
///
/// In October 2026 xAI retired the SuperGrok lineup and renamed its tiers to
/// the X Subscription ladder (Plus, Premium, Super, Ultra). The Grok CLI's
/// `_x.ai/billing` call still reports the retired SKU name: a live capture from
/// an X Subscription **Ultra** account returned `"SuperGrok Heavy"`, while the
/// Grok app and Cursor's `GetPlanInfo` both call the same plan "Ultra". Showing
/// the raw token made MeterBar disagree with the vendor's own UI.
///
/// The mapping follows xAI's price ladder: SuperGrok ($30) kept its price as
/// Premium, SuperGrok Plus ($100) is Super, SuperGrok Heavy is Ultra (the top
/// consumer tier), and SuperGrok Lite is Plus. Any other token (current names,
/// X Premium, Business, an unknown future name) is returned unchanged.
nonisolated enum XSubscriptionPlanName {
    private static let retiredNames: [String: String] = [
        "supergrok heavy": "Ultra",
        "supergrok plus": "Super",
        "supergrok lite": "Plus",
        "supergrok": "Premium",
    ]

    static func current(for token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let key = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
        return retiredNames[key] ?? trimmed
    }
}
