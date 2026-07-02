import AppKit
import MeterBarShared
import SwiftUI

/// Color tokens for MeterBar.
///
/// MeterBar relies on semantic system colors and native containers so the UI
/// adapts to light/dark, the user's accent, Increase Contrast, and Reduce
/// Transparency. The only custom colors are the per-provider brand accents and
/// quota status — and those are kept appearance-adaptive too. Glass/material is
/// supplied by the system chrome layer (popover, sidebar, toolbar), not here.
enum MeterBarTheme {
    // MARK: - Brand accents (semantic indicators only; adapt to light/dark)

    static let codexAccent = Color.adaptive(
        light: NSColor(srgbRed: 0 / 255, green: 122 / 255, blue: 168 / 255, alpha: 1),
        dark: NSColor(srgbRed: 100 / 255, green: 210 / 255, blue: 255 / 255, alpha: 1)
    )
    static let claudeAccent = Color.adaptive(
        light: NSColor(srgbRed: 176 / 255, green: 86 / 255, blue: 52 / 255, alpha: 1),
        dark: NSColor(srgbRed: 209 / 255, green: 134 / 255, blue: 101 / 255, alpha: 1)
    )
    static let cursorAccent = Color.adaptive(
        light: NSColor(srgbRed: 34 / 255, green: 150 / 255, blue: 92 / 255, alpha: 1),
        dark: NSColor(srgbRed: 99 / 255, green: 210 / 255, blue: 151 / 255, alpha: 1)
    )
    static let openaiAccent = Color.adaptive(
        light: NSColor(srgbRed: 16 / 255, green: 163 / 255, blue: 127 / 255, alpha: 1),
        dark: NSColor(srgbRed: 106 / 255, green: 216 / 255, blue: 185 / 255, alpha: 1)
    )

    /// The app's own accent. Follows the user's system accent color.
    static let appAccent = Color.accentColor

    // MARK: - Quota status (system colors; adapt to appearance + Increase Contrast)

    static let success = Color(nsColor: .systemGreen)
    // systemOrange (not systemYellow) keeps the amber "Tight" band visually
    // distinct from green/red at caption sizes (PR #33).
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    static func accent(for service: ServiceType) -> Color {
        switch service {
        case .claudeCode:
            return claudeAccent
        case .codexCli:
            return codexAccent
        case .cursor:
            return cursorAccent
        }
    }

    static func accent(for provider: ApiProvider) -> Color {
        switch provider {
        case .anthropic:
            return claudeAccent
        case .openai:
            return openaiAccent
        }
    }

    static func quotaStatusColor(percentLeft: Int) -> Color {
        QuotaBand.forPercentLeft(percentLeft).color
    }
}

extension QuotaBand {
    /// Appearance-adaptive color for the band (single place where severity
    /// maps to color, shared by every surface).
    var color: Color {
        switch self {
        case .healthy: return MeterBarTheme.success
        case .tight: return MeterBarTheme.warning
        case .critical, .exhausted: return MeterBarTheme.danger
        }
    }
}

struct MeterBarDetailBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

extension View {
    /// Shared content-card surface used by both the popover and the dashboard.
    /// An opaque system control background (not a material) with concentric
    /// continuous corners, so cards never stack glass-on-glass — chrome glass
    /// belongs to the window, sidebar, toolbar, and popover controls. A hairline
    /// separator keeps the card from disappearing into the companion background.
    func meterBarCardSurface(cornerRadius: CGFloat = 12) -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }
}

extension Color {
    /// An appearance-adaptive color backed by a dynamic `NSColor`, resolving the
    /// correct value for light / dark (and optionally high-contrast) appearances.
    static func adaptive(
        light: NSColor,
        dark: NSColor,
        lightHighContrast: NSColor? = nil,
        darkHighContrast: NSColor? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ]) {
            case .darkAqua: return dark
            case .accessibilityHighContrastAqua: return lightHighContrast ?? light
            case .accessibilityHighContrastDarkAqua: return darkHighContrast ?? dark
            default: return light
            }
        })
    }
}
