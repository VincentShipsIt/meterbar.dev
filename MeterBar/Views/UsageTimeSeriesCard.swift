import Charts
import MeterBarShared
import SwiftUI

/// Token-type colors, shared by the chart's "Token type" stacking and the
/// breakdown table's composition bar so a color means one thing on the page.
/// Cache reads are the bulk of most usage, so they take the quiet gray and let
/// input, output and cache writes carry the color.
extension TokenKind {
    var color: Color {
        switch self {
        case .input: return .blue
        case .output: return .purple
        case .cacheWrite: return .teal
        case .cacheRead: return .gray
        }
    }
}

/// The one time series on the Usage page. Replaces "Daily spend" (Swift Charts,
/// dollars) and "Token Burn" (a hand-rolled bar view, tokens, no y-axis), which
/// drew the same daily rows twice.
struct UsageTimeSeriesCard: View {
    let report: UsageReport
    let statusText: String?
    let isScanning: Bool
    let scanProgress: CostScanProgress?

    @AppStorage(StorageKeys.usageChartMetric)
    private var metricRawValue = UsageMetric.tokens.rawValue
    @AppStorage(StorageKeys.usageChartStacking)
    private var stackingRawValue = UsageStacking.provider.rawValue

    /// Stored choices can be stale (an old build, a hand-edited default), and
    /// Cost cannot be stacked by token type, so the resolved selection is always
    /// one the chart can draw.
    private var selection: UsageChartSelection {
        UsageChartSelection(
            metric: UsageMetric(rawValue: metricRawValue) ?? .tokens,
            stacking: UsageStacking(rawValue: stackingRawValue) ?? .provider
        ).normalized()
    }

    /// Dimmed while a scan refreshes rows that are already on screen.
    private var contentOpacity: Double { isScanning ? 0.42 : 1 }

    var body: some View {
        DashboardCard(title: "Usage over time", trailing: statusText ?? report.selection.subtitle) {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
                controls

                ZStack {
                    chart
                        .opacity(contentOpacity)

                    if isScanning {
                        CostScanProgressBadge(compact: false, progress: scanProgress)
                    }
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeterBarTheme.Spacing.md) {
                metricPicker
                stackingPicker
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                metricPicker
                stackingPicker
            }
        }
    }

    private var metricPicker: some View {
        Picker("Metric", selection: Binding(
            get: { selection.metric },
            set: { newMetric in
                metricRawValue = newMetric.rawValue
                // Leaving Token type for Cost would otherwise leave a stored
                // choice the chart has to ignore on every render.
                stackingRawValue = UsageChartSelection(metric: newMetric, stacking: selection.stacking)
                    .normalized().stacking.rawValue
            }
        )) {
            ForEach(UsageMetric.allCases) { metric in
                Text(metric.title).tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Chart metric")
    }

    private var stackingPicker: some View {
        HStack(spacing: MeterBarTheme.Spacing.sm) {
            Text("Stack by")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Stack by", selection: Binding(
                get: { selection.stacking },
                set: { stackingRawValue = $0.rawValue }
            )) {
                ForEach(UsageStacking.available(for: selection.metric)) { stacking in
                    Text(stacking.title).tag(stacking)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Stack chart by")
        }
    }

    // MARK: - Chart

    @ViewBuilder private var chart: some View {
        let series = report.series(selection)
        if series.points.isEmpty {
            EmptyStateCard(
                systemImage: "chart.bar.xaxis",
                title: "No usage in this window",
                message: "No \(selection.metric == .cost ? "billable " : "")usage was found in the "
                    + "\(report.selection.subtitle.lowercased())."
            )
            .frame(height: Self.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                Chart(series.points) { point in
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value(series.metric.title, point.value)
                    )
                    .foregroundStyle(by: .value(series.stacking.title, point.category))
                    .accessibilityLabel(
                        "\(point.category), \(point.date.formatted(date: .abbreviated, time: .omitted))"
                    )
                    .accessibilityValue(Self.formattedValue(point.value, metric: series.metric))
                }
                .chartForegroundStyleScale(
                    domain: series.categories.map(\.name),
                    range: series.categories.enumerated().map { Self.color(for: $0.element, at: $0.offset) }
                )
                .chartXScale(domain: report.chartDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: Self.axisStride(days: report.windowDays))) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(Self.formattedValue(amount, metric: series.metric))
                            }
                        }
                    }
                }
                .chartLegend(position: .top, alignment: .leading, spacing: MeterBarTheme.Spacing.sm)
                .frame(height: Self.chartHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    "\(series.metric.title) per day, stacked by \(series.stacking.title.lowercased()), "
                        + report.selection.subtitle.lowercased()
                )
            }
        }
    }

    // MARK: - Pure helpers

    static let chartHeight: CGFloat = 240

    /// Roughly five labels whatever the window: every day for a week, every
    /// fifth for a month.
    static func axisStride(days: Int) -> Int {
        max(1, Int((Double(days) / 6).rounded()))
    }

    static func formattedValue(_ value: Double, metric: UsageMetric) -> String {
        switch metric {
        case .tokens: return UsageFormat.compactTokens(value)
        case .cost: return UsageFormat.cost(value)
        }
    }

    /// Provider categories use the provider accent, token types their own
    /// colors, and models a categorical run — two Claude models drawn in one
    /// accent would be indistinguishable.
    static func color(for category: UsageSeriesCategory, at index: Int) -> Color {
        if let provider = category.provider { return MeterBarTheme.accent(for: provider) }
        if let kind = category.kind { return kind.color }
        switch category.name {
        case "Unattributed": return .gray
        case "Other": return Color.secondary
        default: return modelPalette[index % modelPalette.count]
        }
    }

    private static let modelPalette: [Color] = [.blue, .purple, .teal, .pink, .indigo]
}
