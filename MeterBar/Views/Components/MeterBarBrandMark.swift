import SwiftUI

// MARK: - MeterBarBrand

/// The app icon's own palette, transcribed from `docs/logo.svg` and
/// `Assets.xcassets/AppIcon.appiconset`.
///
/// The share cards used to head themselves with stand-in SF Symbols — a white
/// circle around `chart.bar.xaxis` on the token card, `gauge.with.needle.fill`
/// on the limits card — so a posted screenshot carried a mark that appears
/// nowhere else in the product. These are the icon's actual stops, which lets
/// the mark below be *the* logo rather than a likeness of it, and lets the
/// cards' severity ramp inherit the same three colors the icon already spends
/// on healthy / warning / critical.
enum MeterBarBrand {
    /// Icon plate gradient (`#1a1a2e` → `#0f0f1a`).
    static let plateTop = Color(red: 0.102, green: 0.102, blue: 0.180)
    static let plateBottom = Color(red: 0.059, green: 0.059, blue: 0.102)
    /// The unfilled part of a meter bar (`#2a2a4a`).
    static let barTrack = Color(red: 0.165, green: 0.165, blue: 0.290)

    /// `#4ade80` — the icon's healthy bar.
    static let green = Color(red: 0.290, green: 0.871, blue: 0.502)
    /// `#fbbf24` — the icon's warning bar.
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)
    /// `#f87171` — the light half of the icon's critical bar.
    static let red = Color(red: 0.973, green: 0.443, blue: 0.443)
    /// `#ef4444` — the saturated half of the icon's critical bar, kept for the
    /// one state that is worse than critical.
    static let deepRed = Color(red: 0.937, green: 0.267, blue: 0.267)
}

// MARK: - MeterBarBrandMark

/// MeterBar's actual mark: three meter bars at 30 / 55 / 85% on the icon's dark
/// plate.
///
/// Drawn natively rather than loaded from `AppIcon`, for two reasons. The asset
/// catalog's app icon is not addressable as an `Image` from the widget-sharing
/// code path, and — the deciding one — the share cards are rasterized by
/// `ImageRenderer` at 1200×675 from a preview laid out at a third of that, so a
/// bitmap would resample twice. Shapes stay crisp at both sizes.
///
/// Geometry is expressed as fractions of the *plate* (the icon's 448pt inner
/// square), not of the 512pt canvas, so a mark placed at `size` occupies
/// exactly `size` with no transparent margin to visually center around.
struct MeterBarBrandMark: View {
    // MARK: Lifecycle

    init(size: CGFloat) {
        self.size = size
    }

    // MARK: Internal

    /// Fill fractions of the three bars, top to bottom, with the icon's color
    /// for each. Internal so the card layer can assert the mark it ships is
    /// still the icon's ramp.
    static let bars: [(fill: CGFloat, color: Color)] = [
        (0.30, MeterBarBrand.green),
        (0.55, MeterBarBrand.amber),
        (0.85, MeterBarBrand.red),
    ]

    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * Self.plateCornerFraction, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MeterBarBrand.plateTop, MeterBarBrand.plateBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    // The plate is darker than the card it sits on is light, and
                    // near-black on near-black loses its silhouette. A hairline
                    // gives the mark an edge without inventing a new shape.
                    RoundedRectangle(cornerRadius: size * Self.plateCornerFraction, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: max(0.5, size * 0.012))
                }

            VStack(spacing: size * Self.barGapFraction) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                    self.bar(fill: bar.fill, color: bar.color)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: Private

    private static let plateCornerFraction: CGFloat = 96.0 / 448.0
    private static let barInsetFraction: CGFloat = 64.0 / 448.0
    private static let barHeightFraction: CGFloat = 44.0 / 448.0
    /// The icon's bars are 82pt apart center to center; the gutter is whatever
    /// that leaves once a bar's own height is taken out. Stacking three bars at
    /// this gutter and centering the stack reproduces the icon's 152 / 234 / 316
    /// rows exactly, without positioning each bar by hand.
    private static let barGapFraction: CGFloat = (82.0 - 44.0) / 448.0

    private func bar(fill: CGFloat, color: Color) -> some View {
        let width = size - (size * Self.barInsetFraction * 2)

        return ZStack(alignment: .leading) {
            Capsule().fill(MeterBarBrand.barTrack)
            Capsule().fill(color).frame(width: width * fill)
        }
        .frame(width: width, height: size * Self.barHeightFraction)
    }
}
