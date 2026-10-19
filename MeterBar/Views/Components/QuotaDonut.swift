import MeterBarShared
import SwiftUI

/// Display rules for one quota window drawn as a donut, with no SwiftUI
/// attached so each rule is directly assertable.
///
/// Only a Session or Weekly window that reports a measured percent qualifies.
/// Credits, estimated totals, currency windows and model or pool windows have
/// nothing a ring can honestly show, so they stay bars.
struct QuotaDonutContent: Equatable {
    enum Tone: Equatable {
        case healthy
        case tight
        case critical
    }

    let percentLeft: Int
    /// What is left, 0...1: the share of the ring that is filled.
    let fractionLeft: Double
    let tone: Tone

    init?(limit: SnapshotLimit) {
        let usage = limit.usageLimit
        guard limit.kind == .session || limit.kind == .weekly,
              limit.valueStyle == .quota,
              usage.reading == .measured,
              !usage.isEstimated,
              usage.total > 0
        else { return nil }

        percentLeft = limit.percentLeft
        fractionLeft = min(1, max(0, 1 - usage.rawPercentage / 100))
        switch QuotaBand.forLimit(usage) {
        case .healthy: tone = .healthy
        case .tight: tone = .tight
        case .critical, .exhausted: tone = .critical
        }
    }

    func centerText(locale: Locale = .current) -> String {
        (Double(percentLeft) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

/// A Session or Weekly window as a ring with its title and reset countdown
/// beside it. The popover shows this; the hover panel behind it has the bar,
/// the runway chart and the week of usage.
struct QuotaDonut: View {
    static let diameter: CGFloat = 46
    static let lineWidth: CGFloat = 6

    let limit: SnapshotLimit
    let accentColor: Color
    var resetTimeFormat: ResetTimeFormat = .countdown

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var content: QuotaDonutContent? { QuotaDonutContent(limit: limit) }

    var body: some View {
        if let content {
            HStack(spacing: 8) {
                ring(content)
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.localizedTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if limit.usageLimit.resetTime != nil {
                        ResetCountdownLabel(
                            title: nil,
                            limit: limit.usageLimit,
                            font: .caption2,
                            foregroundColor: .secondary,
                            iconSize: 9,
                            format: resetTimeFormat
                        )
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.localizedAccessibilityLabel)
            .accessibilityValue(limit.localizedAccessibilityValue)
        }
    }

    private func color(for tone: QuotaDonutContent.Tone) -> Color {
        switch tone {
        case .healthy: accentColor
        case .tight: MeterBarTheme.warning
        case .critical: MeterBarTheme.danger
        }
    }

    private func ring(_ content: QuotaDonutContent) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: Self.lineWidth)
            if content.fractionLeft > 0 {
                Circle()
                    .trim(from: 0, to: content.fractionLeft)
                    .stroke(
                        color(for: content.tone),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Text(verbatim: content.centerText())
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .numericRefreshTransition(value: content.centerText(), reduceMotion: reduceMotion)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .padding(Self.lineWidth / 2)
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standardCurve, reduceMotion: reduceMotion),
            value: content.fractionLeft
        )
    }
}

/// The popover card's Session and Weekly donuts, side by side.
struct QuotaDonutRow: View {
    let limits: [SnapshotLimit]
    let accentColor: Color
    var resetTimeFormat: ResetTimeFormat = .countdown

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(limits) { limit in
                QuotaDonut(limit: limit, accentColor: accentColor, resetTimeFormat: resetTimeFormat)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
