import SwiftUI

/// A single, unified capsule chip for MeterBar's small status/tier/role badges.
///
/// Before this existed, five near-identical recipes had drifted apart
/// (`ExtraUsageStatusPill`, `ReadinessBadge`, `ProviderStatusBadge`, the
/// Optimize tier badge, and the Settings role capsule) — each with its own
/// padding, fill opacity, and stroke. `MeterBarChip` collapses them onto one
/// padding scale and one stroke treatment so the badges read as one system.
/// Callers keep control of *meaning* (tint + label); the chip owns *styling*.
///
/// Two styles cover every current use:
/// - ``Style/flat``: a tinted fill (with a matching hairline stroke) for badges
///   that sit inside an opaque card and need to separate from it by color.
/// - ``Style/glass``: a Liquid-Glass capsule (`.glassEffect`) for chips that
///   overlay live content or window chrome, where a flat tint would look muddy.
struct MeterBarChip: View {
    /// Surface treatment for the chip. See the type doc for when to use each.
    enum Style: Equatable {
        /// Tinted fill + hairline stroke, for in-card badges.
        case flat
        /// `.glassEffect` capsule, for chips overlaying content/chrome.
        case glass
    }

    /// One padding scale + one stroke/fill treatment for every chip.
    ///
    /// These are the *single* standardized values the five legacy recipes used
    /// to disagree on. They intentionally live here rather than in
    /// `MeterBarTheme` because no radius/opacity design token has landed yet.
    ///
    /// Follow-up (not yet actionable): once the radius/opacity design-token
    /// chip lands in `MeterBarTheme`, fold these constants into it so chips and
    /// cards share the same tokens instead of hard-coding them here.
    enum Metrics {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 3
        static let iconTextSpacing: CGFloat = 4
        static let iconPointSize: CGFloat = 10
        static let fillOpacity: Double = 0.14
        static let strokeOpacity: Double = 0.18
        static let strokeWidth: CGFloat = 1
    }

    let text: String
    let systemImage: String?
    let tint: Color
    var style: Style = .flat

    init(_ text: String, systemImage: String? = nil, tint: Color, style: Style = .flat) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.style = style
    }

    var body: some View {
        content
            .modifier(ChipSurface(tint: tint, style: style))
    }

    private var content: some View {
        HStack(spacing: Metrics.iconTextSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: Metrics.iconPointSize, weight: .semibold))
            }
            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

/// The shared padding + capsule background for a chip. Split into its own
/// `ViewModifier` so `.flat` and `.glass` differ only in the background layer,
/// never in the padding scale.
private struct ChipSurface: ViewModifier {
    let tint: Color
    let style: MeterBarChip.Style

    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, MeterBarChip.Metrics.horizontalPadding)
            .padding(.vertical, MeterBarChip.Metrics.verticalPadding)

        switch style {
        case .flat:
            padded
                .background(tint.opacity(MeterBarChip.Metrics.fillOpacity), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            tint.opacity(MeterBarChip.Metrics.strokeOpacity),
                            lineWidth: MeterBarChip.Metrics.strokeWidth
                        )
                }
        case .glass:
            padded
                .glassEffect(.regular, in: .capsule)
        }
    }
}
