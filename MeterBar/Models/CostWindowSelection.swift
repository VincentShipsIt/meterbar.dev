import Foundation

/// The Costs page's reporting-window toggle: last 7 days, last 30 days, or
/// calendar month-to-date.
///
/// Presentation-only — every window is cut from the one cached 30-day scan
/// (`CostSummary.dailyCostWindow` / `monthToDateCostWindow`), so switching
/// never triggers a rescan. Stored `7` and `30` keep working; `-1` is the
/// calendar month. An unknown stored count falls back to the rolling month.
nonisolated enum CostWindowSelection: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case monthToDate = -1

    var id: Int { rawValue }

    /// Rolling-window day count. Month-to-date uses the live calendar span
    /// instead; call `dayCount(now:calendar:)` when the start of the month
    /// matters.
    var days: Int {
        switch self {
        case .week, .month: return rawValue
        case .monthToDate: return 0
        }
    }

    func dayCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        switch self {
        case .week, .month:
            return rawValue
        case .monthToDate:
            let start = Self.monthStart(now: now, calendar: calendar)
            return max(1, (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0) + 1)
        }
    }

    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .week, .month:
            return CostWindow.start(days: rawValue, now: now, calendar: calendar)
        case .monthToDate:
            return Self.monthStart(now: now, calendar: calendar)
        }
    }

    /// Segment title in the window picker.
    var pickerLabel: String {
        switch self {
        case .week, .month: return "\(rawValue) days"
        case .monthToDate: return "This month"
        }
    }

    /// Card subtitle naming the window, shared by the estimate card and the
    /// Daily Details trailing caption so they cannot drift.
    var subtitle: String {
        switch self {
        case .week, .month: return "Last \(rawValue) days"
        case .monthToDate: return "Month to date"
        }
    }

    /// Title of the spend-chart card.
    var spendCardTitle: String {
        switch self {
        case .week, .month: return "\(rawValue) Day Spend"
        case .monthToDate: return "Month-to-Date Spend"
        }
    }

    /// Calendar width used when hourly rows are unavailable. Old seven-day
    /// caches keep their existing two-week fallback; month windows keep the
    /// existing six-week calendar.
    var fallbackActivityWeeks: Int {
        switch self {
        case .week: return 2
        case .month, .monthToDate: return TokenActivityCalendar.defaultWeeks
        }
    }

    func costWindow(
        from summary: CostSummary,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyCostWindow {
        switch self {
        case .week, .month:
            return summary.dailyCostWindow(lastDays: rawValue, now: now, calendar: calendar)
        case .monthToDate:
            return summary.monthToDateCostWindow(now: now, calendar: calendar)
        }
    }

    private static func monthStart(now: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
    }
}
