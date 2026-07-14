import MeterBarShared
import SwiftUI

/// The per-provider facts the Providers settings tab renders.
///
/// Before this type, the settings view carried ~7 helpers
/// (`providerSourceText`, `providerStatusText`, `providerStatusColor`,
/// `providerPlanText`, `providerHasAccess`, `providerErrorText`, plan/tier
/// formatting) that each re-`switch`ed over `ServiceType`. That spread one
/// provider's display rules across a dozen call sites, so a change to, say, the
/// Claude plan string had to be made in several places.
///
/// `ProviderSettingsFacts` collapses those switches to a single point: the view
/// gathers each provider's *primitive* live state once (via one `switch`) and
/// this value type derives every displayed string/color from it. Because the
/// derivation takes plain values, it is unit-testable without live services.
struct ProviderSettingsFacts {
    let service: ServiceType
    /// Whether the provider is toggled on in Tracked Providers.
    let isEnabled: Bool
    /// Whether the provider's local credentials/CLI are reachable.
    let hasAccess: Bool
    /// Raw subscription/plan token from the provider service (unformatted).
    let subscriptionType: String?
    /// Claude-only rate-limit tier token (unformatted); `nil` for others.
    let rateLimitTier: String?
    /// Last refresh error, already localized; `nil` when the last refresh was clean.
    let errorText: String?
    /// Human "Updated …" string derived from the newest snapshot for this provider.
    let updatedText: String
    /// The single most-severe quota band across this provider's windows.
    let worstBand: QuotaBand?
    /// Display path of the Codex auth file (only used by the Codex source line).
    let codexAuthFileDisplayPath: String

    /// Where MeterBar reads this provider's usage from — shown in the header
    /// subtitle and the Overview "Source" row.
    var sourceText: String {
        switch service {
        case .claudeCode:
            "Claude CLI /usage"
        case .codexCli:
            "\(codexAuthFileDisplayPath) + ChatGPT usage API"
        case .cursor:
            "Cursor local state + usage API"
        case .openRouter:
            "OpenRouter credits + key APIs"
        }
    }

    /// Formatted plan/tier line for the Overview "Plan" row; `nil` when the
    /// provider reports nothing plan-shaped (e.g. OpenRouter).
    var planText: String? {
        switch service {
        case .claudeCode:
            let plan = subscriptionType?.capitalized
            let tier = rateLimitTier?
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return [plan, tier].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .codexCli:
            return subscriptionType?.capitalized.nilIfEmpty
        case .cursor:
            return subscriptionType?.capitalized.nilIfEmpty
        case .openRouter:
            return nil
        }
    }

    /// One-word connection/health status shown in the Overview "Status" row.
    var statusText: String {
        guard isEnabled else {
            return "Disabled"
        }
        guard hasAccess else {
            return "Not connected"
        }
        if errorText != nil {
            return "Refresh failed"
        }
        if let worstBand {
            return worstBand.shortLabel
        }
        return "Waiting for refresh"
    }

    /// Color paired with `statusText`. Secondary until the provider is both
    /// enabled and connected; warning on error; otherwise the band color.
    var statusColor: Color {
        guard isEnabled, hasAccess else {
            return .secondary
        }
        if errorText != nil {
            return MeterBarTheme.warning
        }
        if let worstBand {
            return worstBand.color
        }
        return .secondary
    }
}

extension QuotaBand {
    /// Ordering used to pick the single most-severe band across a provider's
    /// windows. Higher = worse.
    var severity: Int {
        switch self {
        case .healthy:
            0
        case .tight:
            1
        case .critical:
            2
        case .exhausted:
            3
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
