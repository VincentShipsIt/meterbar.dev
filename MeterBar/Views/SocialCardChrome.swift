import MeterBarShared
import SwiftUI

// MARK: - SocialCardPalette

/// Card-native colors, shared by every exported card.
///
/// The in-app surfaces use appearance-adaptive theme tokens; a card is a fixed
/// dark bitmap that will be posted onto someone else's timeline, so it carries
/// its own ramp. That ramp is now the app icon's (`MeterBarBrand`) instead of a
/// second, unrelated set of saturated colors — the mark in the header and the
/// bars in the body come from the same three stops.
enum SocialCardPalette {
    static let surface = Color(white: 0.05)
    static let track = Color(white: 0.18)
    /// Ground for the install command and the stat cells, a touch above the
    /// card surface so they read as plates rather than as body copy.
    static let commandPlate = Color(white: 0.10)
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.42)
    /// Ink for text sitting on top of a filled accent, never pure black.
    static let onAccentText = Color(white: 0.06)
    /// The token receipt's accent. The receipt has no severity to report, so it
    /// takes the icon's middle bar rather than a band color.
    static let receiptAccent = MeterBarBrand.amber

    static func accent(for band: QuotaBand?) -> Color {
        guard let band else { return Color(white: 0.55) }
        switch band {
        case .healthy: return MeterBarBrand.green
        case .tight: return MeterBarBrand.amber
        case .critical: return MeterBarBrand.red
        case .exhausted: return MeterBarBrand.deepRed
        }
    }
}

// MARK: - SocialCardHeader

/// The masthead every card wears: the real mark, the wordmark, what this
/// particular card is about, and whatever status the card wants on the right.
///
/// Shared rather than duplicated because the two cards had already drifted —
/// different logos, different type sizes, different vertical rhythm — which is
/// exactly what makes a pair of cards in one gallery look like a pair of
/// unrelated cards in one gallery.
struct SocialCardHeader<Trailing: View>: View {
    let context: String
    /// A quieter second line of identity, for a card that speaks for a pool
    /// carved out of someone else's account ("Grok Bot **on Cursor**").
    let contextQualifier: String?
    let providerLogo: ProviderLogoKind?
    let scale: CGFloat
    @ViewBuilder let trailing: Trailing

    init(
        context: String,
        contextQualifier: String? = nil,
        providerLogo: ProviderLogoKind? = nil,
        scale: CGFloat,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.context = context
        self.contextQualifier = contextQualifier
        self.providerLogo = providerLogo
        self.scale = scale
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14 * scale) {
            MeterBarBrandMark(size: 44 * scale)

            Text(SocialShareCardContent.appName)
                .font(.system(size: 32 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack(spacing: 9 * scale) {
                Text("·")
                    .font(.system(size: 28 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialCardPalette.tertiaryText)

                if let providerLogo {
                    // Sized to the provider name it sits beside, and drawn in
                    // near-white rather than the secondary grey. At 24pt of
                    // grey on near-black the mark read as "an icon", not as
                    // Codex. Deliberately not the provider's brand accent:
                    // those tokens are appearance-adaptive, and a card is a
                    // fixed dark bitmap with no appearance to adapt to.
                    ProviderLogoView(
                        kind: providerLogo,
                        size: 30 * scale,
                        foregroundColor: .white.opacity(0.9)
                    )
                }

                Text(context)
                    .font(.system(size: 28 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialCardPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let contextQualifier {
                    Text(contextQualifier)
                        .font(.system(size: 20 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(SocialCardPalette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .layoutPriority(1)

            trailing

            Spacer(minLength: 12 * scale)
        }
    }
}

// MARK: - SocialCardChip

/// The filled status capsule on the right of a card's masthead.
struct SocialCardChip: View {
    let text: String
    let accent: Color
    let scale: CGFloat

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 18 * scale, weight: .black, design: .monospaced))
            .tracking(1.6 * scale)
            .foregroundStyle(SocialCardPalette.onAccentText)
            .lineLimit(1)
            .padding(.horizontal, 19 * scale)
            .padding(.vertical, 11 * scale)
            .background(accent, in: Capsule())
    }
}

// MARK: - SocialCardFooter

/// The card's call to action. A copy-pasteable install line converts a feed
/// screenshot into an installed app in one hop, which a repo URL cannot; the
/// site name stays on the right for anyone who wants to read before they run
/// anything.
struct SocialCardFooter: View {
    let tagline: String
    let accent: Color
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 20 * scale) {
            VStack(alignment: .leading, spacing: 9 * scale) {
                HStack(spacing: 10 * scale) {
                    Text("$")
                        .font(.system(size: 21 * scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                    Text(SocialShareCardContent.installCommand)
                        .font(.system(size: 21 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 20 * scale)
                .padding(.vertical, 13 * scale)
                .background(
                    SocialCardPalette.commandPlate,
                    in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(SocialCardPalette.track, lineWidth: max(1, scale))
                }

                Text(tagline)
                    .font(.system(size: 17 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialCardPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 12 * scale)

            Text(SocialShareCardContent.websiteDisplay)
                .font(.system(size: 26 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - SocialCardPlate

/// A tile on a card body — the stat cells and the chart well. One radius, one
/// fill, one hairline, so nothing on a card invents its own container.
struct SocialCardPlate<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content

    init(scale: CGFloat, @ViewBuilder content: () -> Content) {
        self.scale = scale
        self.content = content()
    }

    var body: some View {
        content
            .background(
                SocialCardPalette.commandPlate,
                in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .stroke(SocialCardPalette.track, lineWidth: max(1, scale))
            }
    }
}

// MARK: - SocialCardSurface

/// Shared card scaffold: the flat near-black ground, the scale every interior
/// metric multiplies, and the fixed 56/42 export margins.
struct SocialCardSurface<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.1, min(
                proxy.size.width / SocialShareCardLayout.exportSize.width,
                proxy.size.height / SocialShareCardLayout.exportSize.height
            ))

            ZStack {
                SocialCardPalette.surface

                content(scale)
                    .padding(.horizontal, 56 * scale)
                    .padding(.vertical, 42 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(SocialCardPalette.surface)
    }
}
