import AppKit
import SwiftUI

/// Fixed export geometry for the social share card. The card is rendered to a
/// 1200×675 PNG (standard link-preview / tweet aspect); every interior metric is
/// laid out against `exportSize` and multiplied by a runtime `scale` so the same
/// view fills both the in-app preview and the full-size export bitmap.
enum SocialShareCardLayout {
    static let exportSize = CGSize(width: 1_200, height: 675)
    static let aspectRatio: CGFloat = exportSize.width / exportSize.height
    static let maximumPreviewWidth: CGFloat = 860
    static let reservedVerticalScrollerWidth = NSScroller.scrollerWidth(
        for: .regular,
        scrollerStyle: .legacy
    )

    /// Derives preview geometry from the dashboard viewport, which does not
    /// change when the nested scroll view shows or hides its vertical scroller.
    /// Reserving the legacy scroller width also keeps the explicit frame clear
    /// of non-overlay scrollbars when the user's system preference is "Always."
    static func previewSize(
        viewportWidth: CGFloat,
        horizontalInsets: CGFloat,
        verticalScrollerWidth: CGFloat = reservedVerticalScrollerWidth
    ) -> CGSize {
        let availableWidth = max(
            0,
            viewportWidth - horizontalInsets - verticalScrollerWidth
        )
        let width = min(maximumPreviewWidth, availableWidth)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

/// The rounded, shadowed frame every card preview sits in. Shared so a gallery
/// of mixed cards has one bezel rather than one per card type.
struct SocialCardFrame<Card: View>: View {
    let size: CGSize
    @ViewBuilder let card: Card

    init(size: CGSize, @ViewBuilder card: () -> Card) {
        self.size = size
        self.card = card()
    }

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay { card }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }
}

struct SocialShareCardPreview: View {
    let content: SocialShareCardContent
    let size: CGSize

    var body: some View {
        SocialCardFrame(size: size) {
            SocialShareCard(content: content)
        }
    }
}

/// A deliberately unserious 30-day usage receipt.
///
/// It used to be a purple gradient with blurred orbs, diagonal hatching,
/// scattered sparkles and a rotated sticker — a second visual language that
/// shared nothing with the limits card beyond its dimensions. Now it is the
/// same card: `SocialCardSurface`'s flat near-black ground, the real mark in
/// `SocialCardHeader`, the icon's amber as its accent, and `SocialCardFooter`'s
/// install line. All numbers and text stay in SwiftUI so exported PNGs remain
/// crisp and truthful.
struct SocialShareCard: View {
    let content: SocialShareCardContent

    private var accent: Color { SocialCardPalette.receiptAccent }

    var body: some View {
        SocialCardSurface { scale in
            VStack(alignment: .leading, spacing: 0) {
                // "30-Day Receipt" rather than "Token Receipt" plus a separate
                // "Last 30 days" line: the window is the one fact the identity
                // line was missing, and saying it once leaves the badge alone
                // beside the title, exactly as on the limits card.
                SocialCardHeader(context: "30-Day Receipt", scale: scale) {
                    SocialCardChip(
                        text: content.usageTier.title,
                        accent: accent,
                        scale: scale
                    )
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 52 * scale) {
                    hero(scale: scale)
                        .frame(width: 470 * scale, alignment: .leading)

                    SocialShareStatsColumn(content: content, scale: scale)
                        .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 0)

                SocialCardFooter(
                    tagline: "No fake percentiles. Session data stays on the Mac.",
                    accent: accent,
                    scale: scale
                )
            }
        }
    }

    /// Same three beats as the limits hero — number, what it counts, punchline
    /// — at the one size difference the content forces: a twelve-digit token
    /// total cannot wear the limits card's 168pt face.
    private func hero(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.tokenHeroValue)
                .font(.system(size: 88 * scale, weight: .black, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .padding(.vertical, -8 * scale)

            Text(content.tokenHeroCaption.lowercased())
                .font(.system(size: 24 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialCardPalette.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 10 * scale)
                .frame(maxWidth: 430 * scale, alignment: .leading)

            Text("“\(content.usageTier.joke)”")
                .font(.system(size: 19 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialCardPalette.tertiaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 22 * scale)
                .frame(maxWidth: 430 * scale, alignment: .leading)
        }
    }
}

private struct SocialShareStatsColumn: View {
    let content: SocialShareCardContent
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            SocialShareTokenChart(values: content.dailyTokenTotals, scale: scale)

            HStack(spacing: 12 * scale) {
                SocialShareStatCell(
                    label: "Sessions",
                    value: content.sessionLabel,
                    scale: scale
                )
                SocialShareStatCell(
                    label: "Avg / session",
                    value: content.averageTokensPerSession,
                    scale: scale
                )
            }

            HStack(spacing: 12 * scale) {
                SocialShareStatCell(
                    label: "Active days",
                    value: content.activeDaysLabel,
                    scale: scale
                )
                SocialShareStatCell(
                    label: "Top source",
                    value: content.topProviderLabel,
                    scale: scale
                )
            }
        }
    }
}

private struct SocialShareStatCell: View {
    let label: String
    let value: String
    let scale: CGFloat

    var body: some View {
        SocialCardPlate(scale: scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text(label.uppercased())
                    .font(.system(size: 13 * scale, weight: .black, design: .monospaced))
                    .tracking(0.9 * scale)
                    .foregroundStyle(SocialCardPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(value)
                    .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 13 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SocialShareTokenChart: View {
    let values: [Int]
    let scale: CGFloat

    private var chartValues: [Int] {
        let visibleValues = Array(values.suffix(SocialShareCardContent.chartDayCount))
        return visibleValues.isEmpty
            ? Array(repeating: 0, count: SocialShareCardContent.chartDayCount)
            : visibleValues
    }

    private var maxValue: Int {
        max(chartValues.max() ?? 1, 1)
    }

    private var hasUsage: Bool {
        chartValues.contains(where: { $0 > 0 })
    }

    var body: some View {
        SocialCardPlate(scale: scale) {
            VStack(alignment: .leading, spacing: 14 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                    Text("DAILY BURN")
                        .font(.system(size: 15 * scale, weight: .black, design: .monospaced))
                        .tracking(0.9 * scale)
                        .foregroundStyle(.white)

                    Spacer(minLength: 8 * scale)

                    Text(hasUsage ? "7-day session tokens" : "feed me more sessions")
                        .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(SocialCardPalette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                GeometryReader { proxy in
                    let spacing = max(2 * scale, 1)
                    let barWidth = max(
                        2 * scale,
                        (proxy.size.width - CGFloat(max(0, chartValues.count - 1)) * spacing)
                            / CGFloat(max(1, chartValues.count))
                    )

                    // The ramp belongs to the plot, not to each bar: filling
                    // every bar with its own bottom-to-top gradient painted a
                    // quiet Tuesday the same alarming red as the worst day of
                    // the week. Masking one gradient with the bars means height
                    // alone decides how hot a day looks.
                    LinearGradient(
                        colors: [MeterBarBrand.amber, MeterBarBrand.red],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .opacity(hasUsage ? 1 : 0.22)
                    .mask {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(chartValues.indices, id: \.self) { index in
                                let percent = CGFloat(chartValues[index]) / CGFloat(maxValue)

                                RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                                    .frame(
                                        width: barWidth,
                                        height: max(5 * scale, proxy.size.height * percent)
                                    )
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                    }
                }
                .frame(height: 150 * scale)
            }
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 16 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
