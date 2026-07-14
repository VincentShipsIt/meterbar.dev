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
  // MARK: - Radius scale

  /// Corner-radius scale. Raw radii across the views snap to the nearest step
  /// so cards, chips, and bars read as one system instead of a dozen ad-hoc
  /// values. `shell` matches MacSweep's companion popover / detail-panel shell.
  enum Radius {
    /// Chart bars, legend swatches, inline quota-bar caps/markers. Geometry
    /// often clamps this below 4 on thin (≤2–7pt) shapes, which is intended.
    static let small: CGFloat = 4
    /// Buttons, compact tiles, the API-usage card.
    static let medium: CGFloat = 8
    /// Standard dashboard card.
    static let card: CGFloat = 12
    /// Companion popover + detail-panel shell.
    static let shell: CGFloat = 16

    /// Concentric-radius rule: a rounded child inset by `inset` from a rounded
    /// parent keeps visually parallel corners when its radius is the parent's
    /// radius minus that inset. Used to derive nested-card radii below.
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
      max(0, outer - inset)
    }
  }

  /// A card nested inside the companion shell (16) reads as concentric one
  /// spacing step in → 12 (== `Radius.card`).
  static let detailCardRadius = Radius.concentric(outer: Radius.shell, inset: Spacing.xs)

  /// A card nested inside a standard dashboard card (12) reads as concentric one
  /// spacing step in → 8 (== `Radius.medium`). Used by the API-usage card.
  static let apiCardRadius = Radius.concentric(outer: Radius.card, inset: Spacing.xs)

  /// Matches MacSweep's companion popover and detail-panel shell radius.
  static let companionShellRadius: CGFloat = Radius.shell

  // MARK: - Spacing scale

  /// 4pt spacing grid for padding. Raw padding values snap to the nearest step;
  /// exact ties round up. Replaces the ~15 ad-hoc padding literals in the views.
  enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
  }

  // MARK: - Fill / stroke opacity

  /// Opacity tokens for the recurring tinted fills and hairline strokes on
  /// chips, badges, and quota bars. One-off decorative gradients (cost-card
  /// shimmer, detail-background wash) intentionally keep their own literals.
  enum Fill {
    /// Tinted chip / badge / bar background.
    static let subtle: Double = 0.14
    /// Hairline stroke around a tinted chip / badge.
    static let hairline: Double = 0.18
  }

  // MARK: - Surface vocabulary (the two-layer material system)

  /// MeterBar's surface tokens, codifying Apple's intended two-layer model.
  ///
  /// **Layer 1 — CHROME (glass).** Window and panel shells, headers, floating
  /// controls, and badges that *overlay* content. Rendered with Liquid Glass
  /// (`.glassEffect`) via ``MeterBarCompanionSurface`` and, for detail panes,
  /// ``MeterBarDetailBackground``. Glass belongs to structure that floats above
  /// content — it is deliberately **never** used as a content-card fill (more
  /// glass is not the goal; consistency is). Under Reduce Transparency both
  /// collapse to ``chromeOpaqueFallback`` — good citizenship, preserved.
  ///
  /// **Layer 2 — CONTENT (flat, opaque).** The calm semantic fills that content
  /// sits on. ``content`` is the *single* fill for every dashboard, settings,
  /// and popover card. ``inset`` is a row nested one step inside a content
  /// card. Both are already opaque, so Reduce Transparency leaves them intact.
  ///
  /// The existing "glass shell containing flat-fill cards" structure is the
  /// correct Apple pattern; these tokens make it deliberate rather than
  /// accidental. Radius / spacing / opacity tokens are a separate concern and
  /// intentionally live elsewhere — this enum is fills only.
  enum Surface {
    /// **Layer 1 — chrome.** The Liquid Glass surface (tinted with
    /// ``MeterBarTheme/companionTint``). Use for window / panel shells,
    /// headers, and floating overlays — never for a content card. Preferred
    /// over constructing ``MeterBarCompanionSurface`` directly so the
    /// vocabulary stays the single entry point.
    static func chrome(
      radius: CGFloat = MeterBarTheme.companionShellRadius
    ) -> MeterBarCompanionSurface {
      MeterBarCompanionSurface(radius: radius)
    }

    /// **Layer 1 — chrome fallback.** The opaque fill glass collapses to under
    /// Reduce Transparency. Named so the fallback is deliberate and testable;
    /// consumed by ``MeterBarDetailBackground``.
    static let chromeOpaqueFallback = Color(nsColor: .windowBackgroundColor)

    /// **Layer 2 — content.** The single content-card fill. Every card sits on
    /// this one calm, opaque, appearance-adaptive semantic color. Applied via
    /// ``SwiftUI/View/meterBarCardSurface(cornerRadius:)`` — the one source of
    /// truth for card fills.
    static let content = Color(nsColor: .controlBackgroundColor)

    /// **Layer 2 — inset.** A row nested inside a ``content`` card, one step
    /// recessed. Use for grouped rows *within* a card, not for the card itself.
    static let inset = Color(nsColor: .windowBackgroundColor)
  }

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
  static let grokAccent = Color.adaptive(
    light: NSColor(srgbRed: 33 / 255, green: 103 / 255, blue: 209 / 255, alpha: 1),
    dark: NSColor(srgbRed: 108 / 255, green: 170 / 255, blue: 255 / 255, alpha: 1)
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
    case .grok:
      return grokAccent
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

  // MARK: - Motion (shared animation vocabulary)

  /// The single place MeterBar's animation curves and structural-swap
  /// transitions live. Views reach for these tokens instead of hand-rolling
  /// `.snappy`/`.smooth`/`.easeInOut` so motion stays consistent and Reduce
  /// Motion is honored in one spot. Drive `.animation(_, value:)` off a
  /// *structural* key for the transitions; value ticks (a number rolling on a
  /// refresh) are handled separately by `.contentTransition(.numericText())`.
  enum Motion {
    /// Row expand/collapse and other quick toggles.
    static let quick: Animation = .snappy(duration: 0.18)

    /// In-place status/day disclosure rows (same feel as `quick`, named for intent).
    static let disclosure: Animation = .snappy(duration: 0.18)

    /// Content swaps, status-text changes, `glassEffectID` morphs, and the
    /// popover/card structural state swaps.
    static let standard: Animation = .smooth(duration: 0.32)

    /// Window resize / panel fade.
    static let panel: Animation = .smooth(duration: 0.22)

    // Menu-chrome (AppKit NSPanel) durations, in seconds — used with
    // NSAnimationContext for show/hide/resize. Kept short so the menu bar still
    // feels instant while frame/alpha changes read as a glide, not a snap.
    /// Popover/detail frame resize (expand/collapse, provider appearing).
    static let panelResize: TimeInterval = 0.2
    /// Fade in when a panel is ordered front.
    static let panelFadeIn: TimeInterval = 0.15
    /// Fade out before a panel is ordered out.
    static let panelFadeOut: TimeInterval = 0.12
    /// Status-item alpha change for the parse-health attention state.
    static let statusItemAlpha: TimeInterval = 0.2

    /// Numeric-text rolls and progress-bar fills reacting to a refresh.
    static let standardCurve: Animation = .smooth(duration: 0.35)

    /// Icon/state swaps (chevrons, symbol replace, spinner crossfade).
    static let snappyCurve: Animation = .smooth(duration: 0.22)

    /// Card content swaps (loading / loaded / empty): the outgoing branch softens
    /// out as the incoming one resolves in, no positional jump.
    static let cardPhase = AnyTransition(.blurReplace)

    /// Tiles entering/leaving the popover column: fade while sliding from the top
    /// edge so cards slide+fade rather than pop in place.
    static let popoverTile: AnyTransition = .opacity.combined(with: .move(edge: .top))

    /// Returns `base`, or `nil` under Reduce Motion (an instant, motion-free
    /// update). Plugs straight into `withAnimation(_:)` / `.animation(_:value:)`.
    static func resolve(_ base: Animation, reduceMotion: Bool) -> Animation? {
      reduceMotion ? nil : base
    }

    /// Quicker icon/state-swap curve, or `nil` under Reduce Motion.
    static func snappy(reduceMotion: Bool) -> Animation? {
      reduceMotion ? nil : snappyCurve
    }
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
        // Opaque fallback fills the whole window, bar region included.
        MeterBarTheme.Surface.chromeOpaqueFallback
          .ignoresSafeArea()
      } else {
        // The material is the window backing and may bleed under the toolbar.
        Color.clear
          .background(.regularMaterial)
          .ignoresSafeArea()

        // Keep the accent tint inside the safe area so the macOS 26 automatic
        // scroll-edge effect owns the toolbar region. Apple's guidance is to
        // avoid custom darkening/tinting behind bar items; letting this gradient
        // bleed under the bar (its densest corner is .topLeading) would compete
        // with the system blur/fade that keeps toolbar controls legible.
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
  var radius: CGFloat = MeterBarTheme.Radius.shell

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
  func meterBarCardSurface(cornerRadius: CGFloat = MeterBarTheme.Radius.card) -> some View {
    modifier(MeterBarCardSurfaceModifier(cornerRadius: cornerRadius))
  }

  /// Micro-motion for a numeric `Text` that changes on refresh: the digits roll
  /// via `.numericText()` instead of snapping. `value` is what the caller wants
  /// the transition to key off (usually the underlying number or its formatted
  /// string); when it changes, the animation transaction drives the content
  /// transition. Collapses to an instant update under Reduce Motion.
  func numericRefreshTransition(value: some Equatable, reduceMotion: Bool) -> some View {
    contentTransition(.numericText())
      .animation(
        MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standardCurve, reduceMotion: reduceMotion),
        value: value
      )
  }
}

private struct MeterBarCardSurfaceModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    // Every flat content card funnels through here, so pointing this one
    // modifier at `Surface.content` collapses all card fills onto a single
    // source of truth (behavior-preserving — same semantic color).
    content
      .background(MeterBarTheme.Surface.content, in: shape)
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
