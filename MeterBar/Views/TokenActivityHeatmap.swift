import AppKit
import MeterBarShared
import SwiftUI

/// Dashboard card wrapping the selected token-activity grid.
///
/// Takes plain values rather than reaching for `CostTracker.shared` (same shape
/// as ``CostOverviewStatusCard``) so the card hosts in a test without standing
/// up the scanner. The grid is derived once in `init` — `body` runs on every
/// hover tick, and re-bucketing usage rows there would be wasteful.
struct TokenActivityCard: View {
    private let grid: TokenActivityGrid
    private let isScanning: Bool
    private let isScanDisabled: Bool
    private let scan: () -> Void

    init(
        summary: CostSummary?,
        windowSelection: CostWindowSelection = .month,
        isScanning: Bool,
        isScanDisabled: Bool,
        scan: @escaping () -> Void
    ) {
        self.grid = TokenActivityGrid(summary: summary, windowSelection: windowSelection)
        self.isScanning = isScanning
        self.isScanDisabled = isScanDisabled
        self.scan = scan
    }

    var body: some View {
        DashboardCard(title: "Token Activity", trailing: grid.coverageSummary) {
            if let hourly = grid.hourly {
                TokenActivityHourlyHeatmap(activity: hourly)
            } else if let activity = grid.daily, activity.hasHistory {
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

/// Seven local-day rows by 24 local-hour columns. The model is already fully
/// derived, so pointer and keyboard focus updates only select a stable cell.
struct TokenActivityHourlyHeatmap: View {
    private let activity: TokenActivityHourlyCalendar

    @State private var hoveredHour: TokenActivityHourKey?
    @State private var keyboardHour: TokenActivityHourKey?
    @FocusState private var isGridFocused: Bool
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    init(activity: TokenActivityHourlyCalendar) {
        self.activity = activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: TokenActivityMetrics.spacing) {
                hourHeader
                ForEach(activity.days) { day in
                    dayRow(day)
                }
            }
            .padding(TokenActivityMetrics.focusRingInset)
            .focusable()
            .focused($isGridFocused)
            .onChange(of: isGridFocused) { _, focused in
                guard focused, keyboardHour == nil else { return }
                keyboardHour = activity.busiestHour?.id ?? activity.hours.last?.id
            }
            .onMoveCommand(perform: moveKeyboardSelection)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hourly token activity calendar")
            .accessibilityValue(highlightedCell?.accessibilityValue ?? activity.overviewLine)

            detail
            TokenActivityLegend()
        }
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.quick, reduceMotion: reduceMotion),
            value: highlightedHour
        )
    }

    private var hourHeader: some View {
        HStack(spacing: TokenActivityMetrics.hourlySpacing) {
            Color.clear
                .frame(width: TokenActivityMetrics.weekLabelWidth, height: 1)

            ForEach(0..<TokenActivityHourlyCalendar.hourCount, id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func dayRow(_ day: TokenActivityHourDay) -> some View {
        HStack(spacing: TokenActivityMetrics.hourlySpacing) {
            Text(DashboardDateFormat.monthDay(day.date))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: TokenActivityMetrics.weekLabelWidth, alignment: .trailing)
                .accessibilityHidden(true)

            ForEach(day.hours) { hour in
                cell(for: hour)
            }
        }
    }

    @ViewBuilder
    private func cell(for hour: TokenActivityHour) -> some View {
        let swatch = TokenActivitySwatch(
            level: hour.level,
            isHighlighted: highlightedHour == hour.id,
            fillsWidth: true
        )
        .onHover { isHovering in
            if isHovering {
                hoveredHour = hour.id
            } else if hoveredHour == hour.id {
                hoveredHour = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hour.accessibilityLabel)
        .accessibilityValue(hour.accessibilityValue)

        if highlightedHour == hour.id {
            swatch.help(hour.tooltip)
        } else {
            swatch
        }
    }

    private var detail: some View {
        Text(highlightedCell?.detailLine ?? activity.overviewLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var highlightedHour: TokenActivityHourKey? {
        hoveredHour ?? (isGridFocused ? keyboardHour : nil)
    }

    private var highlightedCell: TokenActivityHour? {
        highlightedHour.flatMap(activity.hour(for:))
    }

    /// The whole 7 × 24 matrix is one tab stop. Arrow keys move the selection
    /// inside it, avoiding 168 focus stops while keeping every hour reachable.
    private func moveKeyboardSelection(_ direction: MoveCommandDirection) {
        guard isGridFocused, !activity.hours.isEmpty else { return }
        let current = keyboardHour.flatMap { key in activity.hours.firstIndex { $0.id == key } }
            ?? activity.hours.indices.last
        guard let current else { return }

        let day = current / TokenActivityHourlyCalendar.hourCount
        let hour = current % TokenActivityHourlyCalendar.hourCount
        let target: Int
        switch direction {
        case .left:
            target = day * TokenActivityHourlyCalendar.hourCount + max(0, hour - 1)
        case .right:
            target = day * TokenActivityHourlyCalendar.hourCount
                + min(TokenActivityHourlyCalendar.hourCount - 1, hour + 1)
        case .up:
            target = max(0, day - 1) * TokenActivityHourlyCalendar.hourCount + hour
        case .down:
            target = min(TokenActivityHourlyCalendar.dayCount - 1, day + 1)
                * TokenActivityHourlyCalendar.hourCount + hour
        default:
            return
        }
        keyboardHour = activity.hours[target].id
    }
}

/// The grid itself: weekday header, one full-width row per week, hover/focus
/// detail, and the intensity legend.
///
/// Weeks run as *rows* with the weekday columns stretched across the card —
/// the transposed month grid was anchored to one edge and left half the card
/// empty, and its 20pt cells were fiddly hover targets.
struct TokenActivityHeatmap: View {
    private let activity: TokenActivityCalendar

    @State private var hoveredDate: Date?
    @FocusState private var focusedDate: Date?
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    init(activity: TokenActivityCalendar) {
        self.activity = activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: TokenActivityMetrics.spacing) {
                weekdayHeader
                ForEach(activity.weeks) { week in
                    weekRow(week)
                }
            }
            // Focus rings sit just outside a cell; without the inset the
            // leading and trailing columns clip theirs against the card.
            .padding(TokenActivityMetrics.focusRingInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Token activity calendar")

            detail
            TokenActivityLegend()
        }
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.quick, reduceMotion: reduceMotion),
            value: highlightedDate
        )
    }

    // MARK: - Grid

    private var weekdayHeader: some View {
        HStack(spacing: TokenActivityMetrics.spacing) {
            Color.clear
                .frame(width: TokenActivityMetrics.weekLabelWidth, height: 1)

            ForEach(Array(activity.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func weekRow(_ week: TokenActivityWeek) -> some View {
        HStack(spacing: TokenActivityMetrics.spacing) {
            // Each row names the day it starts on; a single month header can't
            // label rows that all begin mid-month.
            Text(DashboardDateFormat.monthDay(week.startDate))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: TokenActivityMetrics.weekLabelWidth, alignment: .trailing)
                .accessibilityHidden(true)

            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                if let day {
                    cell(for: day)
                } else {
                    // A future weekday in the current row: the slot still holds
                    // the grid's shape, it just has no cell.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: TokenActivityMetrics.rowHeight)
                }
            }
        }
    }

    private func cell(for day: TokenActivityDay) -> some View {
        TokenActivitySwatch(
            level: day.level,
            isCovered: day.isCovered,
            isHighlighted: highlightedDate == day.date,
            fillsWidth: true
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
/// drift from the cells it explains. Grid cells stretch to their column's
/// width; legend swatches stay fixed squares.
private struct TokenActivitySwatch: View {
    let level: Int
    var isCovered = true
    var isHighlighted = false
    var fillsWidth = false

    var body: some View {
        RoundedRectangle(cornerRadius: TokenActivityMetrics.radius, style: .continuous)
            .fill(TokenActivityPalette.fill(level: level, isCovered: isCovered))
            .overlay {
                RoundedRectangle(cornerRadius: TokenActivityMetrics.radius, style: .continuous)
                    .strokeBorder(borderColor, style: borderStyle)
            }
            .frame(
                minWidth: fillsWidth ? nil : TokenActivityMetrics.cell,
                maxWidth: fillsWidth ? .infinity : TokenActivityMetrics.cell
            )
            .frame(height: fillsWidth ? TokenActivityMetrics.rowHeight : TokenActivityMetrics.cell)
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

/// Grid geometry, kept in one place so the weekday header, week rows, and
/// legend stay on the same rhythm.
private enum TokenActivityMetrics {
    /// Fixed square used by the legend swatches.
    static let cell: CGFloat = 14
    /// Height of a full-width week-row cell.
    static let rowHeight: CGFloat = 26
    /// Leading gutter naming the day each week row starts on.
    static let weekLabelWidth: CGFloat = 52
    static let spacing: CGFloat = 6
    /// A tighter gap preserves useful hover targets across all 24 hour columns.
    static let hourlySpacing: CGFloat = 3
    static let radius: CGFloat = 5
    static let focusRingInset: CGFloat = 2
    /// Placeholder height while a scan runs, matching the loaded grid: the
    /// weekday header plus six week rows and their gaps.
    static let gridHeight: CGFloat = 204
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
