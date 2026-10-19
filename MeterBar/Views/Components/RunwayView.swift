import MeterBarShared
import SwiftUI

/// One quota window drawn as a runway: usage so far against the even-use line,
/// with the current burn rate projected forward, under a headline that states
/// the outcome ("Out by Thu 9am") instead of a percentage.
///
/// Lives in the hover detail panel, one per Session and Weekly window. The
/// popover card keeps plain bars; this is the chart behind them. The chart is
/// annotated so it can be read without a legend lookup: a time axis, a "Now"
/// marker, the shortfall zone when the quota runs out early, and "Full" /
/// "Empty" at the ends of the vertical scale.
///
/// Everything it says comes from `UsageLimit.pace`, so it can never disagree
/// with the bar's pace marker. There is no per-sample history behind the
/// drawn line: it is the average burn since the window opened, which is
/// exactly the rate the projection uses.
struct RunwayView: View {
    let limit: SnapshotLimit
    let accentColor: Color
    var now = Date()

    private var content: RunwayContent? { RunwayContent(limit: limit.usageLimit, now: now) }

    /// Only a Session or Weekly window with a known cadence, reset, and measured
    /// total can be projected; everything else stays a plain `LimitRow`.
    static func isEligible(_ limit: SnapshotLimit, now: Date = Date()) -> Bool {
        RunwayContent.isEligible(limit, now: now)
    }

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.headline)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(Self.outlookColor(content.outlook))
                    Text(content.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                RunwayChart(content: content, accentColor: accentColor, outlook: Self.outlookColor(content.outlook))
                    .frame(height: RunwayChart.height)
                HStack {
                    Text(limit.localizedTitle)
                    Spacer()
                    Text(LocalizedUsageFormat.percentLeft(limit.usageLimit))
                }
                .font(.caption)
                .fontWeight(.semibold)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.localizedAccessibilityLabel)
            .accessibilityValue("\(content.headline). \(content.detail)")
        }
    }

    static func outlookColor(_ outlook: RunwayContent.Outlook) -> Color {
        switch outlook {
        case .lasts: MeterBarTheme.success
        case .shortfall: MeterBarTheme.danger
        }
    }
}

/// Explains the three lines once for every runway in a panel, instead of
/// repeating the key under each chart. The projection swatch is neutral because
/// each chart colours its own projection by outlook (green lasts, red short).
struct RunwayLegend: View {
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            entry("Used so far", color: accentColor, dashed: false)
            entry("Even use", color: Color.secondary.opacity(0.5), dashed: true)
            entry("At this pace", color: Color.primary.opacity(0.7), dashed: true)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .accessibilityHidden(true)
    }

    private func entry(_ title: LocalizedStringKey, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            .frame(width: 14, height: 2)
            Text(title)
        }
    }
}

private struct RunwayChart: View {
    /// Tall enough that the annotations do not crowd the lines: the plot is the
    /// height minus the axis row.
    static let height: CGFloat = 132
    private static let axisHeight: CGFloat = 22
    private static let inset: CGFloat = 4

    let content: RunwayContent
    let accentColor: Color
    let outlook: Color

    private func axisText(_ string: String, weight: Font.Weight = .regular, color: Color = .secondary) -> Text {
        Text(string)
            .font(.system(size: 9, weight: weight))
            .foregroundColor(color)
    }

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(
                x: Self.inset,
                y: Self.inset,
                width: size.width - Self.inset * 2,
                height: size.height - Self.axisHeight - Self.inset
            )
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: plot.minX + p.x * plot.width, y: plot.minY + p.y * plot.height)
            }
            let geometry = content.geometry
            let dash = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3])

            for tick in content.ticks {
                let x = plot.minX + tick.x * plot.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                context.draw(
                    axisText(tick.label),
                    at: CGPoint(x: x + 3, y: plot.maxY + 5),
                    anchor: .topLeading
                )
            }

            if content.outlook == .shortfall {
                let zoneStart = point(geometry.projectionEnd).x
                let zone = CGRect(x: zoneStart, y: plot.minY, width: plot.maxX - zoneStart, height: plot.height)
                context.fill(Path(zone), with: .color(outlook.opacity(0.12)))
                if let shortfall = content.shortfallDuration, zone.width >= 80 {
                    context.draw(
                        axisText("\(shortfall) short", weight: .semibold, color: outlook),
                        at: CGPoint(x: zone.midX, y: plot.minY + 4),
                        anchor: .top
                    )
                }
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: plot.maxY))
            baseline.addLine(to: CGPoint(x: size.width, y: plot.maxY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

            var ideal = Path()
            ideal.move(to: point(geometry.idealStart))
            ideal.addLine(to: point(geometry.idealEnd))
            context.stroke(ideal, with: .color(.secondary.opacity(0.5)), style: dash)

            var actual = Path()
            actual.move(to: point(geometry.actualStart))
            actual.addLine(to: point(geometry.now))
            context.stroke(actual, with: .color(accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            var projection = Path()
            projection.move(to: point(geometry.now))
            projection.addLine(to: point(geometry.projectionEnd))
            context.stroke(projection, with: .color(outlook), style: dash)

            let nowPoint = point(geometry.now)
            context.fill(
                Path(ellipseIn: CGRect(x: nowPoint.x - 3, y: nowPoint.y - 3, width: 6, height: 6)),
                with: .color(accentColor)
            )

            context.draw(
                axisText("Full"),
                at: CGPoint(x: plot.maxX - 2, y: plot.minY + 1),
                anchor: .topTrailing
            )
            context.draw(
                axisText("Empty"),
                at: CGPoint(x: plot.minX + 2, y: plot.maxY - 3),
                anchor: .bottomLeading
            )
            context.draw(
                axisText("Now", weight: .semibold, color: .primary),
                at: CGPoint(x: max(plot.minX + 24, nowPoint.x - 7), y: nowPoint.y + 12),
                anchor: .trailing
            )
        }
        .accessibilityHidden(true)
    }
}

/// Display logic for `RunwayView`, free of SwiftUI so each branch is testable.
struct RunwayContent: Equatable {
    enum Outlook: Equatable {
        case lasts
        case shortfall
    }

    /// Unit square, origin top-left: x is elapsed share of the window, y is
    /// `used` share, so a steeper line is a faster burn and the quota is
    /// spent when it reaches the bottom edge.
    struct Geometry: Equatable {
        let idealStart: CGPoint
        let idealEnd: CGPoint
        let actualStart: CGPoint
        let now: CGPoint
        let projectionEnd: CGPoint
    }

    /// One labelled mark on the time axis. `x` is the elapsed share of the
    /// window, the same scale as `Geometry`.
    struct Tick: Equatable {
        let x: CGFloat
        let label: String
    }

    /// Most labels the axis carries. A longer window is thinned to this so the
    /// labels never crowd each other at the panel's width.
    static let maxTicks = 7

    let outlook: Outlook
    let headline: String
    let detail: String
    let geometry: Geometry
    let resetAt: Date
    let windowSeconds: TimeInterval
    /// How long the quota is gone before the reset, or `nil` when it lasts.
    let shortfallDuration: String?
    /// Hours for a window of a day or less, local midnights for a longer one.
    let ticks: [Tick]

    /// Session and Weekly windows only: model and review windows stay bars.
    static func isEligible(_ limit: SnapshotLimit, now: Date = Date()) -> Bool {
        (limit.kind == .session || limit.kind == .weekly)
            && RunwayContent(limit: limit.usageLimit, now: now) != nil
    }

    init?(limit: UsageLimit, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        guard !limit.isEstimated,
              limit.reading == .measured,
              let reset = limit.resetTime,
              let window = limit.windowSeconds,
              let pace = limit.pace(now: now),
              !pace.isExhausted else { return nil }

        let remaining = reset.timeIntervalSince(now)
        let elapsedShare = min(1, max(0, (window - remaining) / window))
        let usedShare = min(1, limit.rawPercentage / 100)
        let resetText = Self.clock(reset, calendar: calendar, locale: locale)

        let projectionEnd: CGPoint
        if pace.willLastToReset {
            outlook = .lasts
            headline = "Lasts until reset"
            let reserve = Int(abs(pace.deltaPercent).rounded())
            detail = pace.stage == .reserve
                ? "Resets \(resetText) · \(reserve)% in reserve"
                : "Resets \(resetText) · on pace"
            shortfallDuration = nil
            let slope = elapsedShare > 0 ? usedShare / elapsedShare : 0
            projectionEnd = CGPoint(x: 1, y: min(1, slope))
        } else if let eta = pace.etaSeconds {
            outlook = .shortfall
            let emptyAt = now.addingTimeInterval(eta)
            let short = UsageDurationText.short(seconds: remaining - eta)
            headline = "Out by \(Self.clock(emptyAt, calendar: calendar, locale: locale))"
            detail = "Resets \(resetText) · \(short) short"
            shortfallDuration = short
            projectionEnd = CGPoint(x: min(1, elapsedShare + eta / window), y: 1)
        } else {
            return nil
        }

        geometry = Geometry(
            idealStart: .zero,
            idealEnd: CGPoint(x: 1, y: 1),
            actualStart: .zero,
            now: CGPoint(x: elapsedShare, y: usedShare),
            projectionEnd: projectionEnd
        )
        resetAt = reset
        windowSeconds = window
        ticks = Self.axisTicks(resetAt: reset, window: window, calendar: calendar, locale: locale)
    }

    /// "Thu 9 AM" in the user's locale and calendar.
    private static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEj")
        return formatter.string(from: date)
    }

    /// Full hours inside a window of a day or less ("9 AM"), local midnights
    /// inside a longer one ("Thu"). Each is placed by its elapsed share of the
    /// window.
    private static func axisTicks(
        resetAt: Date,
        window: TimeInterval,
        calendar: Calendar,
        locale: Locale
    ) -> [Tick] {
        let start = resetAt.addingTimeInterval(-window)
        let daily = window > 86_400
        let boundary = daily
            ? DateComponents(hour: 0, minute: 0, second: 0)
            : DateComponents(minute: 0, second: 0)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(daily ? "EEE" : "j")

        var ticks: [Tick] = []
        calendar.enumerateDates(
            startingAfter: start,
            matching: boundary,
            matchingPolicy: .nextTime
        ) { date, _, stop in
            guard let date, date < resetAt, ticks.count < 400 else {
                stop = true
                return
            }
            ticks.append(Tick(
                x: CGFloat(date.timeIntervalSince(start) / window),
                label: formatter.string(from: date)
            ))
        }
        return thinned(ticks)
    }

    private static func thinned(_ ticks: [Tick]) -> [Tick] {
        guard ticks.count > maxTicks else { return ticks }
        let stride = Int((Double(ticks.count) / Double(maxTicks)).rounded(.up))
        return ticks.enumerated().filter { $0.offset.isMultiple(of: stride) }.map(\.element)
    }
}
