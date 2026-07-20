import Charts
import MeterBarShared
import SwiftUI

struct CostSpendCharts: View {
    let presentation: CostChartPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xl) {
            if presentation.hasDailyCoverage {
                dailySpendSection
            } else {
                EmptyStateCard(
                    systemImage: "chart.xyaxis.line",
                    title: "Daily spend unavailable",
                    message: "This cached scan has no dated cost rows. Run a new scan to rebuild daily history."
                )
            }

            Divider()

            if presentation.modelPoints.isEmpty {
                EmptyStateCard(
                    systemImage: "chart.bar.xaxis",
                    title: "Model spend unavailable",
                    message: "This cached scan has no model-level cost details."
                )
            } else {
                modelSpendSection
            }
        }
    }

    private var dailySpendSection: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            chartHeading(
                title: "Daily spend",
                value: UsageFormat.cost(presentation.dailyTotalUSD)
            )

            Chart {
                ForEach(presentation.dailyProviderPoints) { point in
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Spend", point.costUSD)
                    )
                    .foregroundStyle(by: .value("Provider", point.provider.displayName))
                    .accessibilityLabel(
                        "\(point.provider.displayName), \(point.date.formatted(date: .abbreviated, time: .omitted))"
                    )
                    .accessibilityValue(UsageFormat.cost(point.costUSD))
                }

                ForEach(presentation.zeroSpendDays) { day in
                    PointMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Spend", 0.0)
                    )
                    .symbolSize(12)
                    .foregroundStyle(.secondary.opacity(0.45))
                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("No spend")
                }
            }
            .chartForegroundStyleScale(
                domain: dailyProviders.map(\.displayName),
                range: providerColors(for: dailyProviders)
            )
            .chartXScale(domain: presentation.startDate ... presentation.chartDomainEndDate)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                currencyYAxisMarks
            }
            .chartLegend(position: .top, alignment: .leading, spacing: MeterBarTheme.Spacing.sm)
            .frame(height: 220)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily spend for the last \(presentation.requestedDays) days")

            Text(dailyCoverageDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSpendSection: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            chartHeading(
                title: "Spend by model",
                value: UsageFormat.cost(presentation.modelTotalUSD)
            )

            Chart(presentation.modelPoints) { point in
                BarMark(
                    x: .value("Spend", point.costUSD),
                    y: .value("Model", point.chartLabel)
                )
                .foregroundStyle(by: .value("Provider", point.provider.displayName))
                .accessibilityLabel("\(point.model), \(point.provider.displayName)")
                .accessibilityValue(UsageFormat.cost(point.costUSD))
            }
            .chartForegroundStyleScale(
                domain: modelProviders.map(\.displayName),
                range: providerColors(for: modelProviders)
            )
            .chartXAxis {
                currencyXAxisMarks
            }
            .chartLegend(position: .top, alignment: .leading, spacing: MeterBarTheme.Spacing.sm)
            .frame(height: max(180, CGFloat(presentation.modelPoints.count) * 30))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spend by model")
            .accessibilityValue(
                "\(presentation.modelPoints.count) models totaling \(UsageFormat.cost(presentation.modelTotalUSD))"
            )

            if presentation.hasUnattributedModelSpend {
                Text("Spend without model metadata is shown as Unattributed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !presentation.modelWindowMatchesRequested {
                Label(
                    "Model detail covers a \(presentation.modelWindowDays)-day cached scan, "
                        + "not the requested \(presentation.requestedDays)-day window.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption2)
                .foregroundStyle(MeterBarTheme.warning)
            }

            if !presentation.modelTotalReconciles {
                Label(
                    "Model detail does not reconcile to the selected-period total.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(MeterBarTheme.warning)
            }
        }
    }

    private var dailyProviders: [ServiceType] {
        Set(presentation.dailyProviderPoints.map(\.provider))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var modelProviders: [ServiceType] {
        Set(presentation.modelPoints.map(\.provider))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func providerColors(for providers: [ServiceType]) -> [Color] {
        providers.map { MeterBarTheme.accent(for: $0) }
    }

    private var dailyCoverageDescription: String {
        if presentation.isDailyCoveragePartial {
            return "Covers \(presentation.coveredDays) of \(presentation.requestedDays) days. "
                + "Earlier days are gaps; missing days inside coverage are $0."
        }
        return "Missing days inside the covered \(presentation.requestedDays)-day window are shown as $0."
    }

    private func chartHeading(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @AxisContentBuilder private var currencyYAxisMarks: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(UsageFormat.cost(amount))
                }
            }
        }
    }

    @AxisContentBuilder private var currencyXAxisMarks: some AxisContent {
        AxisMarks(position: .bottom) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let amount = value.as(Double.self) {
                    Text(UsageFormat.cost(amount))
                }
            }
        }
    }
}
