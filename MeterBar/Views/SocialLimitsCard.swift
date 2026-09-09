import AppKit
import MeterBarShared
import SwiftUI

/// Preview wrapper for the limits card — the same rounded, shadowed frame the
/// token card preview uses, so the two sit as siblings in the gallery.
struct SocialLimitsCardPreview: View {
    let content: SocialLimitsCardContent
    let size: CGSize

    var body: some View {
        SocialCardFrame(size: size) {
            SocialLimitsCard(content: content)
        }
    }
}

/// The quota counterpart to `SocialShareCard`: one provider's live limits as a
/// 1200×675 bitmap. Same export geometry (`SocialShareCardLayout`), the same
/// scale-driven metrics, and the same chrome (`SocialCardSurface`,
/// `SocialCardHeader`, `SocialCardFooter`) — the two cards are one design, not
/// two, which is what lets a gallery of both read as one set.
///
/// The hero is the window the popover's status follows; the stack on the right
/// lists the windows that explain it, each tinted by its own band so a healthy
/// weekly window stays green next to a critical session.
struct SocialLimitsCard: View {
    let content: SocialLimitsCardContent

    var body: some View {
        SocialCardSurface { scale in
            VStack(alignment: .leading, spacing: 0) {
                SocialCardHeader(
                    context: content.providerName,
                    contextQualifier: content.providerQualifier.map { "on \($0)" },
                    providerLogo: content.providerLogo,
                    scale: scale
                ) {
                    // No "Updated 4 sec ago". On a card that is posted the
                    // moment it is exported, a relative timestamp only ever
                    // reads "seconds ago", and by the time anyone else sees it
                    // the number is wrong. The freshness of the data is the
                    // app's problem, not the artwork's. It survives on
                    // `SocialLimitsCardContent.updatedText` for the gallery's
                    // caption sheet, where it is answering a different question.
                    // A badge on the identity line, not a control in the
                    // corner. Parked at the far right it sat 700pt from the
                    // nearest element, where a window control lives, and read
                    // as a button; here "MeterBar · Codex OUT" is one sentence,
                    // and the badge lands in the same place on every card
                    // regardless of how long the hero or the provider name is.
                    SocialCardChip(text: content.statusLabel, accent: accent, scale: scale)
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 52 * scale) {
                    hero(scale: scale)
                        .frame(width: 470 * scale, alignment: .leading)

                    SocialLimitsRowsColumn(content: content, scale: scale)
                        .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 0)

                SocialCardFooter(
                    tagline: "Read from your own account. Nothing leaves the Mac.",
                    accent: accent,
                    scale: scale
                )
            }
        }
    }

    private var accent: Color {
        SocialCardPalette.accent(for: content.band)
    }

    private func hero(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.quotaHeroValue)
                .font(.system(size: 168 * scale, weight: .black, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                // The rounded face leaves generous internal leading; trimming it
                // keeps the caption tucked under the digits instead of floating.
                .padding(.vertical, -14 * scale)

            Text(content.quotaHeroCaption.lowercased())
                .font(.system(size: 24 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialCardPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8 * scale)

            Text(content.tier.joke)
                .font(.system(size: 19 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialCardPalette.tertiaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 22 * scale)
                .frame(maxWidth: 430 * scale, alignment: .leading)
        }
    }
}

private struct SocialLimitsRowsColumn: View {
    let content: SocialLimitsCardContent
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 26 * scale) {
            if content.rows.isEmpty {
                SocialLimitsEmptyRows(scale: scale)
            } else {
                ForEach(content.rows) { row in
                    SocialLimitsRowView(row: row, scale: scale)
                }
            }
        }
    }
}

private struct SocialLimitsEmptyRows: View {
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 26 * scale) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 11 * scale) {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .fill(SocialCardPalette.track)
                        .frame(width: 190 * scale, height: 18 * scale)
                    Capsule()
                        .fill(SocialCardPalette.track)
                        .frame(height: 10 * scale)
                }
            }
        }
    }
}

private struct SocialLimitsRowView: View {
    let row: SocialLimitsCardContent.Row
    let scale: CGFloat

    private var band: QuotaBand { QuotaBand.forPercentLeft(row.percentLeft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                Text(row.title)
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8 * scale)

                Text(row.detailText)
                    .font(.system(size: 18 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialCardPalette.accent(for: band))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SocialCardPalette.track)
                    Capsule()
                        .fill(SocialCardPalette.accent(for: band))
                        .frame(width: max(9 * scale, proxy.size.width * CGFloat(row.usedFraction)))
                }
            }
            .frame(height: 10 * scale)
        }
    }
}
