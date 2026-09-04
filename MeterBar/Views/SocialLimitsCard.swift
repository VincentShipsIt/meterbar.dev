import AppKit
import MeterBarShared
import SwiftUI

/// Preview wrapper for the limits card — the same rounded, shadowed frame the
/// token card preview uses, so the two sit as siblings on the Share page.
struct SocialLimitsCardPreview: View {
    let content: SocialLimitsCardContent
    let size: CGSize

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                SocialLimitsCard(content: content)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }
}

/// The quota counterpart to `SocialShareCard`: one provider's live limits as a
/// 1200×675 bitmap. Same export geometry (`SocialShareCardLayout`) and the same
/// scale-driven metrics, but its own flat, edge-to-edge treatment — the surface
/// runs full bleed with no inner window, and severity is carried by the band
/// color rather than by a decorated backdrop.
///
/// The hero is the window the popover's status follows; the stack on the right
/// lists the windows that explain it, each tinted by its own band so a healthy
/// weekly window stays green next to a critical session.
struct SocialLimitsCard: View {
    let content: SocialLimitsCardContent

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.1, min(
                proxy.size.width / SocialShareCardLayout.exportSize.width,
                proxy.size.height / SocialShareCardLayout.exportSize.height
            ))

            ZStack {
                SocialLimitsPalette.surface

                VStack(alignment: .leading, spacing: 0) {
                    header(scale: scale)

                    Spacer(minLength: 0)

                    HStack(alignment: .center, spacing: 52 * scale) {
                        hero(scale: scale)
                            .frame(width: 470 * scale, alignment: .leading)

                        SocialLimitsRowsColumn(content: content, scale: scale)
                            .frame(maxWidth: .infinity)
                    }

                    Spacer(minLength: 0)

                    footer(scale: scale)
                }
                .padding(.horizontal, 56 * scale)
                .padding(.vertical, 42 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(SocialLimitsPalette.surface)
    }

    private var accent: Color {
        SocialLimitsPalette.accent(for: content.band)
    }

    private func header(scale: CGFloat) -> some View {
        HStack(spacing: 15 * scale) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.system(size: 30 * scale, weight: .black))
                .foregroundStyle(accent)

            Text(SocialShareCardContent.appName)
                .font(.system(size: 32 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("· \(content.providerName)")
                .font(.system(size: 28 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialLimitsPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 12 * scale)

            Text(content.updatedText)
                .font(.system(size: 20 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialLimitsPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(content.statusLabel.uppercased())
                .font(.system(size: 18 * scale, weight: .black, design: .monospaced))
                .tracking(1.6 * scale)
                .foregroundStyle(SocialLimitsPalette.onAccentText)
                .lineLimit(1)
                .padding(.horizontal, 19 * scale)
                .padding(.vertical, 11 * scale)
                .background(accent, in: Capsule())
        }
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
                .foregroundStyle(SocialLimitsPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8 * scale)

            Text(content.tier.joke)
                .font(.system(size: 19 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(SocialLimitsPalette.tertiaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 22 * scale)
                .frame(maxWidth: 430 * scale, alignment: .leading)
        }
    }

    /// The card's call to action. A copy-pasteable install line converts a
    /// feed screenshot into an installed app in one hop, which a repo URL
    /// cannot; the site name stays on the right for anyone who wants to read
    /// before they run anything.
    private func footer(scale: CGFloat) -> some View {
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
                    SocialLimitsPalette.commandPlate,
                    in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(SocialLimitsPalette.track, lineWidth: max(1, scale))
                }

                Text("Read from your own account. Nothing leaves the Mac.")
                    .font(.system(size: 17 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialLimitsPalette.tertiaryText)
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

/// Card-native colors. The in-app surfaces use `QuotaBand.color` (appearance
/// adaptive theme tokens); the card is a fixed dark bitmap, so it carries its
/// own saturated ramp and its own neutrals that read on the near-black ground.
enum SocialLimitsPalette {
    static let surface = Color(white: 0.05)
    static let track = Color(white: 0.18)
    /// Ground for the install command, a touch above the card surface so the
    /// line reads as a terminal snippet rather than as body copy.
    static let commandPlate = Color(white: 0.10)
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.42)
    /// Ink for text sitting on top of a filled accent, never pure black.
    static let onAccentText = Color(white: 0.06)

    static func accent(for band: QuotaBand?) -> Color {
        guard let band else { return Color(white: 0.55) }
        switch band {
        case .healthy: return Color(red: 0.36, green: 0.92, blue: 0.60)
        case .tight: return Color(red: 1.0, green: 0.62, blue: 0.10)
        case .critical: return Color(red: 1.0, green: 0.40, blue: 0.32)
        case .exhausted: return Color(red: 1.0, green: 0.30, blue: 0.42)
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
                        .fill(SocialLimitsPalette.track)
                        .frame(width: 190 * scale, height: 18 * scale)
                    Capsule()
                        .fill(SocialLimitsPalette.track)
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

    /// Used share on the left of the pair, reset on the right — the same two
    /// facts the popover's `LimitRow` prints, in the same order.
    private var detailText: String {
        var parts: [String] = [row.usedPercentText]
        if row.isEstimated {
            parts.append("estimated")
        }
        if let resetText = row.resetText {
            parts.append("resets in \(resetText)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                Text(row.title)
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8 * scale)

                Text(detailText)
                    .font(.system(size: 18 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(SocialLimitsPalette.accent(for: band))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SocialLimitsPalette.track)
                    Capsule()
                        .fill(SocialLimitsPalette.accent(for: band))
                        .frame(width: max(9 * scale, proxy.size.width * CGFloat(row.usedFraction)))
                }
            }
            .frame(height: 10 * scale)
        }
    }
}
