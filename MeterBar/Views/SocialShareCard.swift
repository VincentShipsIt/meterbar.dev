import AppKit
import SwiftUI

/// Fixed export geometry for the social share card. The card is rendered to a
/// 1200×675 PNG (standard link-preview / tweet aspect); every interior metric is
/// laid out against `exportSize` and multiplied by a runtime `scale` so the same
/// view fills both the small in-app preview and the full-size export bitmap.
enum SocialShareCardLayout {
    static let exportSize = CGSize(width: 1_200, height: 675)
    static let aspectRatio: CGFloat = exportSize.width / exportSize.height
}

/// The in-dashboard preview wrapper: keeps the export aspect ratio, clips to a
/// rounded rect, and adds a hairline border + drop shadow so the card reads as a
/// physical shareable object rather than inline content.
struct SocialShareCardPreview: View {
    let content: SocialShareCardContent

    var body: some View {
        Color.clear
            .aspectRatio(SocialShareCardLayout.aspectRatio, contentMode: .fit)
            .overlay {
                SocialShareCard(content: content)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
    }
}

/// The branded share card itself. Rendered both on screen (preview) and to PNG
/// via `ImageRenderer`. Every dimension is expressed as a base value times the
/// geometry-derived `scale`, so the layout is resolution-independent between the
/// preview and the 1200×675 export.
struct SocialShareCard: View {
    let content: SocialShareCardContent

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

                    Spacer(minLength: 18 * scale)

                    HStack(alignment: .bottom, spacing: 34 * scale) {
                        heroCopy(scale: scale)
                        Spacer(minLength: 16 * scale)
                        SocialShareTokenChart(
                            values: content.dailyTokenTotals,
                            hasData: content.hasDailyChartData,
                            accent: MeterBarTheme.codexAccent,
                            scale: scale
                        )
                        .frame(width: 390 * scale, height: 214 * scale)
                    }

                    Spacer(minLength: 24 * scale)

                    footer(scale: scale)
                }
                .padding(.horizontal, 54 * scale)
                .padding(.vertical, 46 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color(red: 0.025, green: 0.027, blue: 0.033))
    }

    private func header(scale: CGFloat) -> some View {
        HStack(alignment: .top) {
            HStack(spacing: 14 * scale) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 27 * scale, weight: .bold))
                        .foregroundStyle(MeterBarTheme.appAccent)
                }
                .frame(width: 58 * scale, height: 58 * scale)

                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(SocialShareCardContent.appName)
                        .font(.system(size: 29 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("local AI usage from the macOS menu bar")
                        .font(.system(size: 17 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }

            Spacer()

            Text("TOKEN MAXING RECEIPTS")
                .font(.system(size: 15 * scale, weight: .black, design: .monospaced))
                .tracking(1.8 * scale)
                .foregroundStyle(.white.opacity(0.68))
                .padding(.horizontal, 15 * scale)
                .padding(.vertical, 9 * scale)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private func heroCopy(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text(content.tokenHeroValue)
                    .font(.system(size: 63 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(content.tokenHeroCaption.uppercased())
                    .font(.system(size: 16 * scale, weight: .bold, design: .monospaced))
                    .tracking(1.2 * scale)
                    .foregroundStyle(MeterBarTheme.codexAccent)
            }

            HStack(spacing: 10 * scale) {
                SocialShareMetricPill(title: "Providers", value: content.sourceLabel, scale: scale)
                SocialShareMetricPill(title: "Estimate", value: content.costLabel, scale: scale)
            }

            VStack(alignment: .leading, spacing: 7 * scale) {
                Text(content.providerLine)
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(content.quotaLine)
                    .font(.system(size: 18 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: 620 * scale, alignment: .leading)
    }

    private func footer(scale: CGFloat) -> some View {
        VStack(spacing: 10 * scale) {
            SocialShareMetadataRow(
                iconName: "globe",
                title: "Website",
                value: SocialShareCardContent.websiteDisplay,
                scale: scale
            )
            SocialShareMetadataRow(
                iconName: "terminal.fill",
                title: "Install",
                value: SocialShareCardContent.installCommand,
                scale: scale
            )
        }
    }
}

private struct SocialShareCardBackground: View {
    let scale: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.022, green: 0.024, blue: 0.030),
                    Color(red: 0.040, green: 0.046, blue: 0.052),
                    Color(red: 0.025, green: 0.030, blue: 0.036)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            SocialShareGridPattern(scale: scale)
                .stroke(Color.white.opacity(0.055), lineWidth: max(0.5, scale))

            VStack {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                MeterBarTheme.codexAccent.opacity(0.0),
                                MeterBarTheme.codexAccent.opacity(0.20),
                                MeterBarTheme.cursorAccent.opacity(0.14)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 5 * scale)
            }
        }
    }
}

private struct SocialShareGridPattern: Shape {
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = max(22, 44 * scale)

        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }

        return path
    }
}

private struct SocialShareMetricPill: View {
    let title: String
    let value: String
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(title.uppercased())
                .font(.system(size: 10 * scale, weight: .black, design: .monospaced))
                .tracking(0.7 * scale)
                .foregroundStyle(.white.opacity(0.44))
            Text(value)
                .font(.system(size: 16 * scale, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 13 * scale)
        .padding(.vertical, 10 * scale)
        .frame(minWidth: 135 * scale, alignment: .leading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 11 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: max(0.5, scale))
        }
    }
}

/// A branded, static bar chart of 30-day local token totals for the export image.
///
/// Deliberately kept separate from the interactive `DailyUsageChart`: this one
/// renders a fixed-size marketing bitmap (dark gradient palette, `scale`-driven
/// geometry, no legend/axis/tooltips), whereas `DailyUsageChart` is a live,
/// system-themed, `DailyTokenUsage`-bound view with `.help()` tooltips that are
/// meaningless in a flattened PNG. The two consume different inputs (`[Int]`
/// daily totals vs. `[DailyTokenUsage]` rows) and share no rendering
/// requirements, so composing them would mean bolting an alternate palette and
/// placeholder mode onto the interactive chart.
///
/// When there is no real usage (`hasData == false`) the chart renders an honest
/// "scan needed" placeholder — a flat dashed baseline, no bars. It never
/// fabricates plausible-looking numbers, so a screenshot can't misrepresent a
/// user who hasn't run a scan.
private struct SocialShareTokenChart: View {
    let values: [Int]
    let hasData: Bool
    let accent: Color
    let scale: CGFloat

    private var maxValue: Int {
        max(values.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text("30d local tokens")
                        .font(.system(size: 17 * scale, weight: .bold))
                        .foregroundStyle(.white)
                    Text(hasData ? "tracked history" : "scan needed")
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18 * scale, weight: .bold))
                    .foregroundStyle(accent)
            }

            if hasData {
                bars
            } else {
                emptyPlaceholder
            }
        }
        .padding(16 * scale)
        .background(Color.white.opacity(0.072), in: RoundedRectangle(cornerRadius: 18 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: max(0.5, scale))
        }
    }

    private var bars: some View {
        GeometryReader { proxy in
            let spacing = max(3 * scale, 2)
            let barWidth = max(
                4 * scale,
                (proxy.size.width - CGFloat(max(0, values.count - 1)) * spacing)
                    / CGFloat(max(1, values.count))
            )

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(values.indices, id: \.self) { index in
                    let percent = CGFloat(values[index]) / CGFloat(maxValue)

                    RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.92),
                                    MeterBarTheme.cursorAccent.opacity(0.74)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: barWidth, height: max(6 * scale, proxy.size.height * percent))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }

    /// Honest "no data yet" state: a dashed baseline with a short caption, drawn
    /// in place of bars so the card reads as empty rather than populated.
    private var emptyPlaceholder: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.03))

                VStack(spacing: 8 * scale) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 26 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.32))
                    Text("Run a cost scan to fill this in")
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Path { path in
                    let y = proxy.size.height - max(2, scale)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
                .stroke(
                    Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: max(1, scale), dash: [6 * scale, 5 * scale])
                )
            }
        }
    }
}

private struct SocialShareMetadataRow: View {
    let iconName: String
    let title: String
    let value: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: iconName)
                .font(.system(size: 15 * scale, weight: .bold))
                .foregroundStyle(MeterBarTheme.codexAccent)
                .frame(width: 24 * scale)
            Text(title.uppercased())
                .font(.system(size: 12 * scale, weight: .black, design: .monospaced))
                .tracking(0.8 * scale)
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 64 * scale, alignment: .leading)
            Text(value)
                .font(.system(size: 18 * scale, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.52)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15 * scale)
        .padding(.vertical, 11 * scale)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: max(0.5, scale))
        }
    }
}
