import Charts
import MeterBarShared
import SwiftUI

/// The dashboard home for polled series that are not denominated in dollars.
///
/// Cursor reports a request counter against a plan allowance and publishes no
/// rate to price it with, so it is barred from the spend chart, the cost total
/// and the share card — all three are money. This card is where it appears
/// instead, counted in requests and captioned with the date tracking began, so
/// the stretch before MeterBar's first poll reads as unmeasured rather than as
/// a quiet run of zeroes.
struct PolledUsageCard: View {
    let presentation: PolledRequestSeriesPresentation

    var body: some View {
        DashboardCard(title: "Polled Usage", trailing: "Last \(presentation.requestedDays) days") {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
                Text(
                    "These providers report a running counter, not a cost, and keep no local logs. "
                        + "MeterBar counts the change between its own polls, so this is usage, not spend."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                ForEach(presentation.providers, id: \.provider) { series in
                    PolledUsageProviderRow(series: series)
                }
            }
        }
    }
}

private struct PolledUsageProviderRow: View {
    let series: PolledRequestSeriesPresentation.ProviderSeries

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            HStack(spacing: 10) {
                ProviderTitle(
                    title: series.provider.displayName,
                    logoKind: .forService(series.provider),
                    color: MeterBarTheme.accent(for: series.provider),
                    font: .subheadline
                )
                Spacer()
                Text(series.formattedTotal)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(series.provider.displayName)
            .accessibilityValue(series.formattedTotal)

            if series.hasNoMeasuredDays {
                EmptyStateCard(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: "No change observed yet",
                    message: "The counter has not moved since MeterBar started watching it."
                )
            } else {
                chart
            }

            DashboardCardCaption(text: trackingCaption)
        }
    }

    /// Bars only for days that were measured. The x-scale deliberately spans
    /// just the observed range instead of the full window, so unmeasured days
    /// are absent from the axis rather than drawn as empty ground.
    private var chart: some View {
        Chart(series.days, id: \.date) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Requests", day.amount)
            )
            .foregroundStyle(MeterBarTheme.accent(for: series.provider))
            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue("\(UsageFormat.groupedTokens(Int(day.amount.rounded()))) requests")
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .frame(height: 130)
    }

    private var trackingCaption: String {
        let started = series.trackingStartedOn.formatted(date: .abbreviated, time: .omitted)
        return "Counted since \(started). Earlier days were never polled, so they are not shown."
    }
}
