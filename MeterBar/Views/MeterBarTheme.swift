import AppKit
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

    /// The app's own accent. Follows the user's system accent color.
    static let appAccent = Color.accentColor

    // MARK: - Quota status (system colors; adapt to appearance + Increase Contrast)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemYellow)
    static let danger = Color(nsColor: .systemRed)

    static func accent(for service: ServiceType) -> Color {
        switch service {
        case .claude, .claudeCode:
            return claudeAccent
        case .codexCli, .openai:
            return codexAccent
        case .cursor:
            return cursorAccent
        }
    }

    static func quotaStatusColor(percentLeft: Int) -> Color {
        if percentLeft <= 10 { return danger }
        if percentLeft <= 25 { return warning }
        return success
    }

    static func metricColor(percentLeft: Int) -> Color {
        percentLeft <= 0 ? danger : .primary
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
