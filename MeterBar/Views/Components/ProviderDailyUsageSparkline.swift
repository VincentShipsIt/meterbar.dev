import MeterBarShared
import SwiftUI

/// The seven-day bar strip in the hover detail panel.
///
/// The reason the panel exists. Everything else it draws — the header, the limit
/// rows — the card underneath already drew; only the row footers get wordier.
/// This is the one thing the card cannot show, because a card that fits three to
/// a popover has no room for a week of history.
///
/// Deliberately a strip and not ``DailyUsageChart``: that chart is a 30-day
/// dashboard element with a legend, month labels and stacked per-provider
/// segments. At 340pt those columns would be hairlines, and the panel is
/// provider-scoped anyway, so there is nothing to stack.
///
/// Takes a fully built ``ProviderDailyUsageSeries`` rather than reaching for
/// ``CostTracker``, matching ``TokenActivityCard``: the panel is hosted in tests
/// without standing up the scanner, and the bucketing must not re-run in `body`
/// on every hover tick.
struct ProviderDailyUsageSparkline: View {
    let series: ProviderDailyUsageSeries
    let accentColor: Color

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    // Bars grow from the baseline as the panel appears. Gated on Reduce Motion
    // via `Motion.resolve`, which returns nil and makes `withAnimation` a plain
    // assignment — the same gate `LimitRow` and `ProviderComponents` use.
    @State private var isRevealed = false

    private let barHeight: CGFloat = 34
    private let barCornerRadius: CGFloat = 2.5

    var body: some View {
        // Spacing and a quiet label, never a rule: the panel is the same card the
        // pointer is resting on, only wider, so it must not sprout chrome the
        // card never had.
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
            sectionHeader

            if series.hasHistory {
                bars
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.accessibilityLabel)
        .accessibilityValue(series.accessibilityValue)
    }

    // MARK: - Pieces

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Last \(series.days.count) days")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: MeterBarTheme.Spacing.sm)

            if series.hasHistory {
                // The unit noun follows the metric, so a Cursor request count can
                // never be printed as though it were money.
                Text("\(series.formattedTotal) \(series.metric.summaryNoun)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(series.days) { day in
                VStack(spacing: 3) {
                    bar(for: day)
                    Text(day.weekdayLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(helpText(for: day))
            }
        }
        .onAppear {
            withAnimation(
                MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.disclosure, reduceMotion: reduceMotion)
            ) {
                isRevealed = true
            }
        }
    }

    private func bar(for day: ProviderDailyUsageSeries.Day) -> some View {
        // The track is always drawn so the strip reads as seven days even when
        // most of them are quiet. An unobserved day gets the track and no fill —
        // there is no figure to draw, and a zero-height bar would claim there was.
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(day.isMeasured ? 0.14 : 0.07))

            if day.isMeasured, day.value > 0 {
                RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous)
                    .fill(accentColor.opacity(0.85))
                    .frame(height: isRevealed ? filledHeight(for: day) : 0)
            }
        }
        .frame(height: barHeight)
    }

    private var emptyState: some View {
        EmptyStateCard(
            systemImage: "chart.bar",
            title: emptyTitle,
            message: emptyMessage
        )
    }

    // MARK: - Copy

    /// Two genuinely different situations. A log-scanning provider is one scan
    /// away from a full week of history; a polled provider can only ever be
    /// waiting, because there is no history to fetch — see
    /// ``ProviderUsageLedger``.
    private var emptyTitle: String {
        series.service.writesLocalTokenLogs ? "No token history yet" : "No usage recorded yet"
    }

    private var emptyMessage: String {
        series.service.writesLocalTokenLogs
            ? "Run a cost scan to load \(series.service.shortName)'s daily usage."
            : "\(series.service.shortName) publishes no history, so MeterBar builds this from its own refreshes."
    }

    /// Only shown when the strip is drawing something, so it qualifies the bars
    /// rather than replacing them.
    private var caption: String? {
        if series.isCombinedAcrossAccounts {
            // The honest version of a limitation that would otherwise be
            // invisible: the cost cache has no account dimension, so a
            // per-account card's panel shows every account's usage.
            return "Across all \(series.service.shortName) accounts"
        }
        if series.hasPartialCoverage, let start = series.coverageStart {
            return "Tracked since \(ProviderDailyUsageFormat.weekdayAndDate(start, calendar: .current))"
        }
        return nil
    }

    private func helpText(for day: ProviderDailyUsageSeries.Day) -> String {
        guard day.isMeasured else { return "\(day.longLabel): not tracked yet" }
        return "\(day.longLabel): \(series.metric.formatted(day.value))"
    }

    // MARK: - Geometry

    /// Scaled against the tallest day in the window, with a floor so a day that
    /// is small but not empty still reads as a mark rather than nothing.
    private func filledHeight(for day: ProviderDailyUsageSeries.Day) -> CGFloat {
        let peak = series.peakValue
        guard peak > 0 else { return 0 }
        return max(2, barHeight * CGFloat(day.value / peak))
    }
}
