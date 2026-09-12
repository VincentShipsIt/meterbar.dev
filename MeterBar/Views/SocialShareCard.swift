import AppKit
import MeterBarShared
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
                    VStack(alignment: .leading, spacing: 0) {
                        hero(scale: scale)

                        // The models sit under the hero rather than in the
                        // stats grid opposite: they are the one block on the
                        // card whose row count varies with the data, and the
                        // hero column is the only one with slack to spend on
                        // it.
                        if content.hasModelBreakdown {
                            SocialShareModelBreakdown(
                                slices: content.modelSlices,
                                largestTokens: content.largestModelTokens,
                                scale: scale
                            )
                            .padding(.top, 24 * scale)
                        }
                    }
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
            SocialShareTokenChart(
                days: content.dailyBurn,
                providers: content.chartProviders,
                scale: scale
            )

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
    let days: [SocialShareDayBurn]
    let providers: [ServiceType]
    let scale: CGFloat

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
                        (proxy.size.width - CGFloat(max(0, chartDays.count - 1)) * spacing)
                            / CGFloat(max(1, chartDays.count))
                    )

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(chartDays.indices, id: \.self) { index in
                            bar(chartDays[index], width: barWidth, plotHeight: proxy.size.height)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                }
                .frame(height: 138 * scale)

                // A stack of colors is only readable with the key beside it.
                // The legend is built from the days actually drawn, so it can
                // never name a provider the week has no segment for.
                if hasUsage, !providers.isEmpty {
                    HStack(spacing: 16 * scale) {
                        ForEach(providers) { provider in
                            HStack(spacing: 7 * scale) {
                                Circle()
                                    .fill(SocialCardPalette.provider(provider))
                                    .frame(width: 10 * scale, height: 10 * scale)

                                Text(provider.shortName)
                                    .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                                    .foregroundStyle(SocialCardPalette.secondaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 16 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The gap between two stacked segments. The card's own plate shows
    /// through it, which is what keeps Codex's blue and Grok's blue from
    /// reading as one taller Codex.
    private var segmentGap: CGFloat { max(2 * scale, 1) }

    private var chartDays: [SocialShareDayBurn] {
        let visibleDays = Array(days.suffix(SocialShareCardContent.chartDayCount))
        return visibleDays.isEmpty
            ? Array(
                repeating: SocialShareDayBurn(slices: []),
                count: SocialShareCardContent.chartDayCount
            )
            : visibleDays
    }

    private var maxValue: Int {
        max(chartDays.map(\.tokens).max() ?? 1, 1)
    }

    private var hasUsage: Bool {
        chartDays.contains { $0.tokens > 0 }
    }

    /// One day, bottom-anchored and clipped as a single rounded bar so the
    /// segments inside it stay square-edged against each other.
    ///
    /// Segments are stacked in `providers` order — the week's order, biggest at
    /// the base — rather than in the day's own. A per-day sort flips the stack
    /// the moment the lead changes hands, and two bars assembled in different
    /// orders cannot be compared by eye at all.
    private func bar(_ day: SocialShareDayBurn, width: CGFloat, plotHeight: CGFloat) -> some View {
        let height = max(5 * scale, plotHeight * CGFloat(day.tokens) / CGFloat(maxValue))
        let present = providers.filter { day.tokens(for: $0) > 0 }
        let gaps = segmentGap * CGFloat(max(0, present.count - 1))
        let fillHeight = max(0, height - gaps)

        return VStack(spacing: segmentGap) {
            if present.isEmpty {
                // An honest empty day: the track, not a colored stub that
                // would claim a provider burned something.
                Rectangle()
                    .fill(SocialCardPalette.track)
            } else {
                ForEach(present.reversed()) { provider in
                    Rectangle()
                        .fill(SocialCardPalette.provider(provider))
                        .frame(
                            height: max(
                                2 * scale,
                                fillHeight * CGFloat(day.tokens(for: provider)) / CGFloat(max(1, day.tokens))
                            )
                        )
                }
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous))
    }
}

/// The receipt's answer to "on what?".
///
/// The card reported a total, a week's shape and a top *provider*, which stops
/// one question short of the one people actually post these for. Each row is
/// its provider's color — stepped back by rank so two Claude models are two
/// rows rather than one block — and the chart legend above names those colors.
private struct SocialShareModelBreakdown: View {
    let slices: [SocialShareModelSlice]
    let largestTokens: Int
    let scale: CGFloat

    var body: some View {
        SocialCardPlate(scale: scale) {
            VStack(alignment: .leading, spacing: 13 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                    Text("TOP MODELS")
                        .font(.system(size: 15 * scale, weight: .black, design: .monospaced))
                        .tracking(0.9 * scale)
                        .foregroundStyle(.white)

                    Spacer(minLength: 8 * scale)

                    Text("30-day tokens")
                        .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(SocialCardPalette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                VStack(alignment: .leading, spacing: 11 * scale) {
                    ForEach(slices) { slice in
                        row(slice)
                    }
                }
            }
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 16 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ slice: SocialShareModelSlice) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(spacing: 10 * scale) {
                Text(slice.name)
                    .font(.system(size: 18 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Spacer(minLength: 8 * scale)

                Text(slice.formattedTokens)
                    .font(.system(size: 18 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(SocialCardPalette.secondaryText)
                    .lineLimit(1)
            }

            // Drawn against the biggest model rather than against the window
            // total: model attribution can cover less than every token, and a
            // bar claiming a share of the whole would overstate every row.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SocialCardPalette.track)

                    Capsule()
                        .fill(SocialCardPalette.model(slice.provider, providerRank: slice.providerRank))
                        .frame(
                            width: max(
                                6 * scale,
                                proxy.size.width * CGFloat(slice.tokens) / CGFloat(max(1, largestTokens))
                            )
                        )
                }
            }
            .frame(height: 7 * scale)
        }
    }
}
