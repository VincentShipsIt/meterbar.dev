import MeterBarShared
import SwiftUI

/// The weekly window drawn as a runway: usage so far against the even-use
/// line, with the current burn rate projected forward, under a headline that
/// states the outcome ("Out by Thu 9am") instead of a percentage.
///
/// Everything it says comes from `UsageLimit.pace`, so it can never disagree
/// with the bar's pace marker. There is no per-sample history behind the
/// drawn line: it is the average burn since the window opened, which is
/// exactly the rate the projection uses.
struct RunwayView: View {
    let limit: SnapshotLimit
    let accentColor: Color
    var now: Date = Date()

    private var content: RunwayContent? { RunwayContent(limit: limit.usageLimit, now: now) }

    /// Only a window with a known cadence, reset, and measured total can be
    /// projected; everything else stays a plain `LimitRow`.
    static func isEligible(_ limit: SnapshotLimit, now: Date = Date()) -> Bool {
        limit.kind == .weekly && RunwayContent(limit: limit.usageLimit, now: now) != nil
    }

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.headline)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(color(for: content.outlook))
                    Text(content.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                RunwayChart(geometry: content.geometry, accentColor: accentColor, outlook: color(for: content.outlook))
                    .frame(height: 36)
                HStack {
                    Text(limit.localizedTitle)
                    Spacer()
                    Text(LocalizedUsageFormat.percentLeft(limit.usageLimit))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.localizedAccessibilityLabel)
            .accessibilityValue("\(content.headline). \(content.detail)")
        }
    }

    private func color(for outlook: RunwayContent.Outlook) -> Color {
        switch outlook {
        case .lasts: MeterBarTheme.success
        case .shortfall: MeterBarTheme.danger
        }
    }
}

private struct RunwayChart: View {
    let geometry: RunwayContent.Geometry
    let accentColor: Color
    let outlook: Color

    var body: some View {
        Canvas { context, size in
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * size.width, y: p.y * size.height)
            }
            let dash = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3])

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
        }
        .overlay(alignment: .bottom) { Divider() }
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

    let outlook: Outlook
    let headline: String
    let detail: String
    let geometry: Geometry

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
            let slope = elapsedShare > 0 ? usedShare / elapsedShare : 0
            projectionEnd = CGPoint(x: 1, y: min(1, slope))
        } else if let eta = pace.etaSeconds {
            outlook = .shortfall
            let emptyAt = now.addingTimeInterval(eta)
            headline = "Out by \(Self.clock(emptyAt, calendar: calendar, locale: locale))"
            detail = "Resets \(resetText) · \(UsageDurationText.short(seconds: remaining - eta)) short"
            projectionEnd = CGPoint(x: min(1, elapsedShare + eta / window), y: 1)
        } else {
            return nil
        }

        geometry = Geometry(
            idealStart: CGPoint(x: 0, y: 0),
            idealEnd: CGPoint(x: 1, y: 1),
            actualStart: CGPoint(x: 0, y: 0),
            now: CGPoint(x: elapsedShare, y: usedShare),
            projectionEnd: projectionEnd
        )
    }

    /// "Thu 9 AM" in the user's locale and calendar.
    private static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEj")
        return formatter.string(from: date)
    }
}
