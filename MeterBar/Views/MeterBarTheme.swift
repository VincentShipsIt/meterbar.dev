import AppKit
import MeterBarShared
import SwiftUI

/// Color tokens for MeterBar.
///
/// MeterBar relies on semantic system colors and native containers so the UI
/// adapts to light/dark, the user's accent, Increase Contrast, and Reduce
/// Transparency. The only custom colors are the per-provider brand accents and
/// quota status — and those are kept appearance-adaptive too.
enum MeterBarTheme {
  /// Matches MacSweep's companion popover and detail-panel shell radius.
  static let companionShellRadius: CGFloat = 16

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
  static let openRouterAccent = Color.adaptive(
    light: NSColor(srgbRed: 105 / 255, green: 82 / 255, blue: 188 / 255, alpha: 1),
    dark: NSColor(srgbRed: 177 / 255, green: 159 / 255, blue: 255 / 255, alpha: 1)
  )

  /// The app's own accent. Follows the user's system accent color.
  static let appAccent = Color.accentColor

  static let sidebarMenuTint = Color.adaptive(
    light: NSColor(srgbRed: 82 / 255, green: 108 / 255, blue: 118 / 255, alpha: 1),
    dark: NSColor(srgbRed: 112 / 255, green: 143 / 255, blue: 154 / 255, alpha: 1),
    lightHighContrast: NSColor(srgbRed: 50 / 255, green: 78 / 255, blue: 90 / 255, alpha: 1),
    darkHighContrast: NSColor(srgbRed: 145 / 255, green: 176 / 255, blue: 188 / 255, alpha: 1)
  )

  static let companionTint = Color.adaptive(
    light: NSColor(srgbRed: 0.50, green: 0.66, blue: 0.72, alpha: 0.16),
    dark: NSColor(srgbRed: 0.08, green: 0.20, blue: 0.24, alpha: 0.18),
    lightHighContrast: NSColor(srgbRed: 0.50, green: 0.66, blue: 0.72, alpha: 0.20),
    darkHighContrast: NSColor(srgbRed: 0.08, green: 0.20, blue: 0.24, alpha: 0.20)
  )

  // MARK: - Quota status (system colors; adapt to appearance + Increase Contrast)

  static let success = Color(nsColor: .systemGreen)
  // systemOrange (not systemYellow) keeps the amber "Tight" band visually
  // distinct from green/red at caption sizes (PR #33).
  static let warning = Color(nsColor: .systemOrange)
  static let danger = Color(nsColor: .systemRed)

  static let glassCardStroke = Color.adaptive(
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
    dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06),
    lightHighContrast: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14),
    darkHighContrast: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
  )

  static func accent(for service: ServiceType) -> Color {
    switch service {
    case .claudeCode:
      return claudeAccent
    case .codexCli:
      return codexAccent
    case .cursor:
      return cursorAccent
    case .openRouter:
      return openRouterAccent
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
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  var body: some View {
    ZStack {
      if reduceTransparency {
        Color(nsColor: .windowBackgroundColor)
      } else {
        Color.clear
          .background(.regularMaterial)

        LinearGradient(
          colors: [
            MeterBarTheme.codexAccent.opacity(0.04),
            MeterBarTheme.appAccent.opacity(0.025),
            .clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    }
  }
}

struct MeterBarCompanionSurface: View {
  var radius: CGFloat = 16

  var body: some View {
    Color.clear
      .glassEffect(
        .regular.tint(MeterBarTheme.companionTint),
        in: .rect(cornerRadius: radius, style: .continuous)
      )
  }
}

extension NSPanel {
  func applyCompanionClipping(radius: CGFloat = MeterBarTheme.companionShellRadius) {
    contentView?.wantsLayer = true
    contentView?.layer?.cornerRadius = radius
    contentView?.layer?.cornerCurve = .continuous
    contentView?.layer?.masksToBounds = true
  }
}

extension View {
  func meterBarCardSurface(cornerRadius: CGFloat = 12) -> some View {
    modifier(MeterBarCardSurfaceModifier(cornerRadius: cornerRadius))
  }
}

private struct MeterBarCardSurfaceModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    content
      .background(Color(nsColor: .controlBackgroundColor), in: shape)
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
    Color(
      nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [
          .aqua, .darkAqua,
          .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua: return dark
        case .accessibilityHighContrastAqua: return lightHighContrast ?? light
        case .accessibilityHighContrastDarkAqua: return darkHighContrast ?? dark
        default: return light
        }
      })
  }
}
