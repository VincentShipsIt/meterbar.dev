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
/// 1200×675 receipt. Same export geometry (`SocialShareCardLayout`), same
/// scale-driven metrics, same code-native backdrop — only the payload differs.
/// The hero is the window the popover's status follows; the panel lists the
/// windows that explain it, each drawn with the shared band color.
struct SocialLimitsCard: View {
    let content: SocialLimitsCardContent

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.1, min(
                proxy.size.width / SocialShareCardLayout.exportSize.width,
                proxy.size.height / SocialShareCardLayout.exportSize.height
            ))

            ZStack {
                SocialShareCardBackground(scale: scale)

                VStack(alignment: .leading, spacing: 0) {
                    header(scale: scale)

                    Spacer(minLength: 22 * scale)

                    HStack(alignment: .top, spacing: 36 * scale) {
                        hero(scale: scale)
                            .frame(width: 600 * scale, alignment: .leading)

                        SocialLimitsRowsPanel(content: content, scale: scale)
                            .frame(width: 456 * scale)
                    }

                    Spacer(minLength: 22 * scale)

                    footer(scale: scale)
                }
                .padding(.horizontal, 54 * scale)
                .padding(.vertical, 42 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color(red: 0.035, green: 0.025, blue: 0.075))
    }

    private var accent: Color {
        SocialLimitsPalette.accent(for: content.band)
    }

    private func header(scale: CGFloat) -> some View {
        HStack {
            HStack(spacing: 12 * scale) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 23 * scale, weight: .black))
                        .foregroundStyle(Color(red: 0.16, green: 0.07, blue: 0.31))
                }
                .frame(width: 48 * scale, height: 48 * scale)

                Text(SocialShareCardContent.appName)
                    .font(.system(size: 27 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            Text("QUOTA CHECK  /  \(content.providerName.uppercased())")
                .font(.system(size: 14 * scale, weight: .black, design: .monospaced))
                .tracking(1.2 * scale)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 15 * scale)
                .padding(.vertical, 9 * scale)
                .background(Color.black.opacity(0.24), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.14), lineWidth: max(0.5, scale))
                }
        }
    }

    private func hero(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14 * scale) {
                Text(content.quotaHeroValue)
                    .font(.system(size: 78 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)

                SocialLimitsStatusBadge(
                    label: content.statusLabel,
                    band: content.band,
                    scale: scale
                )
            }

            Text(content.quotaHeroCaption.uppercased())
                .font(.system(size: 16 * scale, weight: .black, design: .monospaced))
                .tracking(1.15 * scale)
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 3 * scale)

            SocialShareTierSticker(
                caption: "QUOTA CLASS",
                title: content.tier.title,
                symbolName: content.tier.symbolName,
                scale: scale
            )
            .padding(.top, 30 * scale)

            Text("“\(content.tier.joke)”")
                .font(.system(size: 23 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .padding(.top, 25 * scale)
                .frame(maxWidth: 570 * scale, alignment: .leading)
        }
    }

    private func footer(scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            Text(SocialShareCardContent.websiteDisplay)
                .font(.system(size: 16 * scale, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Text("•")
                .foregroundStyle(.white.opacity(0.36))

            Text(content.updatedText.uppercased())
                .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                .tracking(0.8 * scale)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 12 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text("READ FROM YOUR OWN ACCOUNT. NOTHING LEAVES THE MAC.")
                .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                .tracking(0.7 * scale)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Card-native severity colors. The in-app surfaces use `QuotaBand.color`
/// (appearance-adaptive theme tokens); the card is a fixed dark bitmap, so it
/// carries its own saturated ramp that reads on the purple backdrop.
enum SocialLimitsPalette {
    static func accent(for band: QuotaBand?) -> Color {
        guard let band else { return Color.white.opacity(0.62) }
        switch band {
        case .healthy: return Color(red: 0.36, green: 0.93, blue: 0.62)
        case .tight: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .critical: return Color(red: 1.0, green: 0.42, blue: 0.36)
        case .exhausted: return Color(red: 1.0, green: 0.30, blue: 0.42)
        }
    }

    static func barGradient(for band: QuotaBand) -> LinearGradient {
        let top: Color
        let bottom: Color
        switch band {
        case .healthy:
            top = Color(red: 0.36, green: 0.93, blue: 0.62)
            bottom = Color(red: 0.16, green: 0.72, blue: 0.62)
        case .tight:
            top = Color(red: 1.0, green: 0.72, blue: 0.25)
            bottom = Color(red: 1.0, green: 0.52, blue: 0.22)
        case .critical, .exhausted:
            top = Color(red: 1.0, green: 0.42, blue: 0.36)
            bottom = Color(red: 1.0, green: 0.30, blue: 0.48)
        }
        return LinearGradient(colors: [bottom, top], startPoint: .leading, endPoint: .trailing)
    }
}

private struct SocialLimitsStatusBadge: View {
    let label: String
    let band: QuotaBand?
    let scale: CGFloat

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 13 * scale, weight: .black, design: .monospaced))
            .tracking(1.0 * scale)
            .foregroundStyle(Color(red: 0.13, green: 0.05, blue: 0.20))
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 6 * scale)
            .background(SocialLimitsPalette.accent(for: band), in: Capsule())
    }
}

private struct SocialLimitsRowsPanel: View {
    let content: SocialLimitsCardContent
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 13 * scale) {
            HStack {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("LIVE WINDOWS")
                        .font(.system(size: 13 * scale, weight: .black, design: .monospaced))
                        .tracking(0.8 * scale)
                        .foregroundStyle(.white)
                    Text(content.hasQuotaData ? "what the popover is watching right now" : "nothing reported yet")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18 * scale, weight: .black))
                    .foregroundStyle(SocialLimitsPalette.accent(for: content.band))
            }

            if content.rows.isEmpty {
                SocialLimitsEmptyRows(scale: scale)
            } else {
                ForEach(content.rows) { row in
                    SocialLimitsRowView(row: row, scale: scale)
                }
            }
        }
        .padding(17 * scale)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: max(0.5, scale))
        }
    }
}

private struct SocialLimitsEmptyRows: View {
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 46 * scale)
            }
        }
    }
}

private struct SocialLimitsRowView: View {
    let row: SocialLimitsCardContent.Row
    let scale: CGFloat

    private var band: QuotaBand { QuotaBand.forPercentLeft(row.percentLeft) }

    /// Pace on the left, reset on the right — the same two facts the popover's
    /// `LimitRow` prints under its bar, in the same order.
    private var detailText: String? {
        var parts: [String] = []
        if row.isEstimated {
            parts.append("Estimated")
        } else if let pace = row.pace {
            parts.append(pace.leftLabel)
        }
        if let resetText = row.resetText {
            parts.append("Resets in \(resetText)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.system(size: 15 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8 * scale)

                Text(row.trailingText)
                    .font(.system(size: 15 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(SocialLimitsPalette.accent(for: band))
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(SocialLimitsPalette.barGradient(for: band))
                        .frame(width: max(6 * scale, proxy.size.width * CGFloat(row.usedFraction)))
                }
            }
            .frame(height: 10 * scale)

            if let detailText {
                Text(detailText)
                    .font(.system(size: 10.5 * scale, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 9 * scale)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
    }
}
