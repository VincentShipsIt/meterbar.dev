import AppKit
import MeterBarShared
import SwiftUI

/// Dashboard card wrapping the trailing contribution calendar.
///
/// Takes plain values rather than reaching for `CostTracker.shared` (same shape
/// as ``CostOverviewStatusCard``) so the card hosts in a test without standing
/// up the scanner. The calendar is derived once in `init` — `body` runs on every
/// hover tick, and re-slicing a year of daily rows there would be wasteful.
struct TokenActivityCard: View {
    private let activity: TokenActivityCalendar
    private let isScanning: Bool
    private let isScanDisabled: Bool
    private let scan: () -> Void

    init(
        summary: CostSummary?,
        isScanning: Bool,
        isScanDisabled: Bool,
        scan: @escaping () -> Void
    ) {
        self.activity = TokenActivityCalendar(summary: summary)
        self.isScanning = isScanning
        self.isScanDisabled = isScanDisabled
        self.scan = scan
    }

    var body: some View {
        DashboardCard(title: "Token Activity", trailing: activity.coverageSummary) {
            if activity.hasHistory {
                TokenActivityHeatmap(activity: activity)
            } else if isScanning {
                CostScanLoadingChart(compact: true)
                    .frame(height: TokenActivityMetrics.gridHeight)
            } else {
                emptyState
            }
        }
    }

    /// The heatmap is empty for exactly the reason the 30-day chart is, so it
    /// reuses that explanation and its scan action rather than inventing a
    /// second wording for the same state.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            EmptyStateCard(
                systemImage: "square.grid.3x3",
                title: "No daily history yet",
                message: "Run a local scan to load 30-day token history."
            )

            Button(action: scan) {
                Label("Scan 30 Days", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glassProminent)
            .disabled(isScanDisabled)
        }
    }
}

/// The grid itself: month headers, weekday gutter, cells, hover/focus detail,
/// and the intensity legend.
struct TokenActivityHeatmap: View {
    private let activity: TokenActivityCalendar
    private let monthTitles: [Int: String]

    @State private var hoveredDate: Date?
    @FocusState private var focusedDate: Date?
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    init(activity: TokenActivityCalendar) {
        self.activity = activity
        self.monthTitles = Dictionary(
            activity.monthLabels.map { ($0.weekIndex, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
                    monthHeader
                    HStack(alignment: .top, spacing: TokenActivityMetrics.spacing) {
                        weekdayGutter
                        grid
                    }
                }
                // Focus rings sit just outside a cell; without the inset the
                // leading and trailing columns clip theirs against the card.
                .padding(TokenActivityMetrics.focusRingInset)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)

            detail
            TokenActivityLegend()
        }
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.quick, reduceMotion: reduceMotion),
            value: highlightedDate
        )
    }

    // MARK: - Grid

    private var grid: some View {
        HStack(alignment: .top, spacing: TokenActivityMetrics.spacing) {
            ForEach(activity.weeks) { week in
                VStack(spacing: TokenActivityMetrics.spacing) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                        if let day {
                            cell(for: day)
                        } else {
                            // A future weekday in the current column: the slot
                            // still holds the grid's shape, it just has no cell.
                            Color.clear
                                .frame(width: TokenActivityMetrics.cell, height: TokenActivityMetrics.cell)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Token activity calendar")
    }

    private func cell(for day: TokenActivityDay) -> some View {
        TokenActivitySwatch(
            level: day.level,
            isCovered: day.isCovered,
            isHighlighted: highlightedDate == day.date
        )
        .focusable()
        .focused($focusedDate, equals: day.date)
        .onHover { isHovering in
            if isHovering {
                hoveredDate = day.date
            } else if hoveredDate == day.date {
                hoveredDate = nil
            }
        }
        .help(day.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilityLabel)
        .accessibilityValue(day.accessibilityValue)
    }

    // MARK: - Headers

    private var monthHeader: some View {
        HStack(alignment: .bottom, spacing: TokenActivityMetrics.spacing) {
            Color.clear
                .frame(width: TokenActivityMetrics.gutterWidth, height: 1)

            ForEach(activity.weeks) { week in
                // `fixedSize` before the column-width frame lets the label keep
                // its natural width and overhang the following columns, which is
                // the only way a month name fits above an 11pt cell.
                Text(monthTitles[week.index] ?? "")
                    .fixedSize()
                    .frame(width: TokenActivityMetrics.cell, alignment: .leading)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var weekdayGutter: some View {
        VStack(spacing: TokenActivityMetrics.spacing) {
            ForEach(Array(activity.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                // Every other row only — seven stacked labels do not fit beside
                // 11pt cells, and the alternating ones still orient the reader.
                Text(index.isMultiple(of: 2) ? "" : symbol)
                    .frame(
                        width: TokenActivityMetrics.gutterWidth,
                        height: TokenActivityMetrics.cell,
                        alignment: .leading
                    )
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: - Detail line

    private var detail: some View {
        Text(highlightedDay?.detailLine ?? activity.overviewLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// Hover wins over focus: the pointer is the more recent intent when both
    /// are live.
    private var highlightedDate: Date? { hoveredDate ?? focusedDate }

    private var highlightedDay: TokenActivityDay? { highlightedDate.flatMap(activity.day(on:)) }
}

// MARK: - Legend

/// Intensity key. The bands are also spelled out in every cell's accessibility
/// value, so the grid never depends on color alone.
private struct TokenActivityLegend: View {
    var body: some View {
        HStack(spacing: MeterBarTheme.Spacing.xs) {
            Text("Less")
            HStack(spacing: TokenActivityMetrics.spacing) {
                ForEach(0...TokenActivityIntensityScale.bandCount, id: \.self) { level in
                    TokenActivitySwatch(level: level)
                }
            }
            Text("More")

            Spacer(minLength: MeterBarTheme.Spacing.sm)

            TokenActivitySwatch(level: 0, isCovered: false)
            Text("No history")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensity legend")
        .accessibilityValue(
            "Cells run from no tracked usage through \(TokenActivityIntensityScale.bandCount) busier bands. "
                + "Outlined cells are days with no retained history."
        )
    }
}

// MARK: - Cell chrome

/// One rounded tile, shared by the grid and the legend so a swatch can never
/// drift from the cells it explains.
private struct TokenActivitySwatch: View {
    let level: Int
    var isCovered = true
    var isHighlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: TokenActivityMetrics.radius, style: .continuous)
            .fill(TokenActivityPalette.fill(level: level, isCovered: isCovered))
            .overlay {
                RoundedRectangle(cornerRadius: TokenActivityMetrics.radius, style: .continuous)
                    .strokeBorder(borderColor, style: borderStyle)
            }
            .frame(width: TokenActivityMetrics.cell, height: TokenActivityMetrics.cell)
    }

    private var borderColor: Color {
        if isHighlighted { return MeterBarTheme.appAccent }
        return isCovered ? Color.clear : TokenActivityPalette.unavailableBorder
    }

    /// Unavailable days get a dashed outline so "no retained history" survives
    /// grayscale, Increase Contrast, and a screenshot.
    private var borderStyle: StrokeStyle {
        if isHighlighted { return StrokeStyle(lineWidth: 1.5) }
        return StrokeStyle(lineWidth: 1, dash: isCovered ? [] : [1.5, 1.5])
    }
}

// MARK: - Metrics and palette

/// Grid geometry, kept in one place so the month header, weekday gutter, cells,
/// and legend stay on the same rhythm.
private enum TokenActivityMetrics {
    static let cell: CGFloat = 11
    static let spacing: CGFloat = 3
    static let radius: CGFloat = 2.5
    static let gutterWidth: CGFloat = 22
    static let focusRingInset: CGFloat = 2
    /// Placeholder height while a scan runs, matching the loaded grid.
    static let gridHeight: CGFloat = 132
}

/// Heatmap band colors.
///
/// The active bands are an opacity ramp on the app accent, so the grid picks up
/// the user's accent like the rest of the dashboard. The neutral tones are
/// explicit adaptive colors instead: an opacity ramp alone all but vanishes
/// under Increase Contrast, and the empty band has to stay legible against both
/// the light and dark card fill.
private enum TokenActivityPalette {
    static let quiet = Color.adaptive(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.10),
        lightHighContrast: NSColor(white: 0, alpha: 0.18),
        darkHighContrast: NSColor(white: 1, alpha: 0.22)
    )

    static let unavailable = Color.clear

    static let unavailableBorder = Color.adaptive(
        light: NSColor(white: 0, alpha: 0.16),
        dark: NSColor(white: 1, alpha: 0.20),
        lightHighContrast: NSColor(white: 0, alpha: 0.34),
        darkHighContrast: NSColor(white: 1, alpha: 0.40)
    )

    private static let bandOpacity: [Double] = [0.32, 0.54, 0.77, 1.0]

    static func fill(level: Int, isCovered: Bool) -> Color {
        guard isCovered else { return unavailable }
        guard level > 0 else { return quiet }
        return MeterBarTheme.appAccent.opacity(bandOpacity[min(level, bandOpacity.count) - 1])
    }
}
