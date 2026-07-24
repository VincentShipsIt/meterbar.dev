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

struct SocialShareCardPreview: View {
    let content: SocialShareCardContent
    let size: CGSize

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                SocialShareCard(content: content)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
    }
}

/// A deliberately unserious 30-day usage receipt. All numbers and text stay in
/// SwiftUI so exported PNGs remain crisp and truthful; the decorative background
/// is also code-native so it never competes with the user's stats.
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

                    Spacer(minLength: 22 * scale)

                    HStack(alignment: .top, spacing: 36 * scale) {
                        hero(scale: scale)
                            .frame(width: 650 * scale, alignment: .leading)

                        SocialShareStatsPanel(content: content, scale: scale)
                            .frame(width: 406 * scale)
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

    private func header(scale: CGFloat) -> some View {
        HStack {
            HStack(spacing: 12 * scale) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 23 * scale, weight: .black))
                        .foregroundStyle(Color(red: 0.16, green: 0.07, blue: 0.31))
                }
                .frame(width: 48 * scale, height: 48 * scale)

                Text(SocialShareCardContent.appName)
                    .font(.system(size: 27 * scale, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            Text("LOCAL RECEIPT  /  LAST 30 DAYS")
                .font(.system(size: 14 * scale, weight: .black, design: .monospaced))
                .tracking(1.2 * scale)
                .foregroundStyle(.white.opacity(0.72))
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
            Text(content.tokenHeroValue)
                .font(.system(size: 78 * scale, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.52)

            Text(content.tokenHeroCaption.uppercased())
                .font(.system(size: 16 * scale, weight: .black, design: .monospaced))
                .tracking(1.15 * scale)
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
                .padding(.top, 3 * scale)

            SocialShareTierSticker(tier: content.usageTier, scale: scale)
                .padding(.top, 30 * scale)

            Text("“\(content.usageTier.joke)”")
                .font(.system(size: 23 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .padding(.top, 25 * scale)
                .frame(maxWidth: 620 * scale, alignment: .leading)
        }
    }

    private func footer(scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            Text(SocialShareCardContent.websiteDisplay)
                .font(.system(size: 16 * scale, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Text("•")
                .foregroundStyle(.white.opacity(0.36))

            Text("NO FAKE PERCENTILES. JUST RECEIPTS.")
                .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                .tracking(0.8 * scale)
                .foregroundStyle(.white.opacity(0.58))

            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 12 * scale, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text("SESSION DATA STAYS LOCAL")
                .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                .tracking(0.7 * scale)
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct SocialShareTierSticker: View {
    let tier: SocialShareUsageTier
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 13 * scale) {
            Image(systemName: tier.symbolName)
                .font(.system(size: 24 * scale, weight: .black))

            VStack(alignment: .leading, spacing: 1 * scale) {
                Text("30-DAY CLASS")
                    .font(.system(size: 10 * scale, weight: .black, design: .monospaced))
                    .tracking(0.8 * scale)
                    .opacity(0.62)
                Text(tier.title)
                    .font(.system(size: 21 * scale, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .foregroundStyle(Color(red: 0.13, green: 0.05, blue: 0.20))
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 11 * scale)
        .background(
            Color(red: 1.0, green: 0.78, blue: 0.25),
            in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .stroke(Color.black.opacity(0.24), lineWidth: max(1, 2 * scale))
        }
        .shadow(color: .black.opacity(0.22), radius: 0, x: 5 * scale, y: 6 * scale)
        .rotationEffect(.degrees(-1.3))
    }
}

private struct SocialShareStatsPanel: View {
    let content: SocialShareCardContent
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 15 * scale) {
            SocialShareTokenChart(values: content.dailyTokenTotals, scale: scale)
                .frame(height: 188 * scale)

            HStack(spacing: 10 * scale) {
                SocialShareStatCell(
                    label: "Sessions",
                    value: content.sessionLabel,
                    symbolName: "bubble.left.and.bubble.right.fill",
                    scale: scale
                )
                SocialShareStatCell(
                    label: "Avg / session",
                    value: content.averageTokensPerSession,
                    symbolName: "divide",
                    scale: scale
                )
            }

            HStack(spacing: 10 * scale) {
                SocialShareStatCell(
                    label: "Active days",
                    value: content.activeDaysLabel,
                    symbolName: "calendar",
                    scale: scale
                )
                SocialShareStatCell(
                    label: "Top source",
                    value: content.topProviderLabel,
                    symbolName: "arrow.up.right",
                    scale: scale
                )
            }
        }
        .padding(17 * scale)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: max(0.5, scale))
        }
    }
}

private struct SocialShareStatCell: View {
    let label: String
    let value: String
    let symbolName: String
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: symbolName)
                Text(label.uppercased())
            }
            .font(.system(size: 10 * scale, weight: .black, design: .monospaced))
            .foregroundStyle(.white.opacity(0.50))

            Text(value)
                .font(.system(size: 17 * scale, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, minHeight: 61 * scale, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
    }
}

private struct SocialShareTokenChart: View {
    let values: [Int]
    let scale: CGFloat

    private var chartValues: [Int] {
        let visibleValues = Array(values.suffix(30))
        return visibleValues.isEmpty ? Array(repeating: 0, count: 30) : visibleValues
    }

    private var maxValue: Int {
        max(chartValues.max() ?? 1, 1)
    }

    private var hasUsage: Bool {
        chartValues.contains(where: { $0 > 0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            HStack {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("DAILY BURN")
                        .font(.system(size: 13 * scale, weight: .black, design: .monospaced))
                        .tracking(0.8 * scale)
                        .foregroundStyle(.white)
                    Text(hasUsage ? "30-day session tokens" : "feed me more sessions")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.50))
                }
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.system(size: 18 * scale, weight: .black))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.28))
            }

            GeometryReader { proxy in
                let spacing = max(2 * scale, 1)
                let barWidth = max(
                    2 * scale,
                    (proxy.size.width - CGFloat(max(0, chartValues.count - 1)) * spacing)
                        / CGFloat(max(1, chartValues.count))
                )

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(chartValues.indices, id: \.self) { index in
                        let value = chartValues[index]
                        let percent = CGFloat(value) / CGFloat(maxValue)

                        RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.72, blue: 0.25),
                                        Color(red: 1.0, green: 0.34, blue: 0.48),
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .opacity(hasUsage ? 0.96 : 0.20)
                            .frame(width: barWidth, height: max(5 * scale, proxy.size.height * percent))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            }
        }
    }
}

private struct SocialShareCardBackground: View {
    let scale: CGFloat

    private let sparklePositions: [CGPoint] = [
        CGPoint(x: 0.09, y: 0.17),
        CGPoint(x: 0.19, y: 0.84),
        CGPoint(x: 0.46, y: 0.10),
        CGPoint(x: 0.73, y: 0.12),
        CGPoint(x: 0.93, y: 0.34),
        CGPoint(x: 0.86, y: 0.88),
        CGPoint(x: 0.55, y: 0.91),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.05, blue: 0.25),
                        Color(red: 0.06, green: 0.03, blue: 0.14),
                        Color(red: 0.03, green: 0.08, blue: 0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color(red: 0.48, green: 0.17, blue: 0.78).opacity(0.34))
                    .frame(width: 620 * scale, height: 620 * scale)
                    .blur(radius: 70 * scale)
                    .offset(x: 430 * scale, y: -310 * scale)

                Circle()
                    .fill(Color(red: 1.0, green: 0.34, blue: 0.26).opacity(0.19))
                    .frame(width: 500 * scale, height: 500 * scale)
                    .blur(radius: 80 * scale)
                    .offset(x: -470 * scale, y: 300 * scale)

                SocialShareDiagonalPattern(scale: scale)
                    .stroke(Color.white.opacity(0.045), lineWidth: max(0.5, scale))

                ForEach(Array(sparklePositions.enumerated()), id: \.offset) { index, position in
                    Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.circle")
                        .font(.system(size: CGFloat(15 + (index % 3) * 5) * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(index.isMultiple(of: 2) ? 0.18 : 0.10))
                        .position(
                            x: proxy.size.width * position.x,
                            y: proxy.size.height * position.y
                        )
                }
            }
        }
    }
}

private struct SocialShareDiagonalPattern: Shape {
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = max(34, 58 * scale)
        var x = rect.minX - rect.height

        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }

        return path
    }
}
