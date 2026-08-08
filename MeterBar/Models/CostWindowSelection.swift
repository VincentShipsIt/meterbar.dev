import Foundation

/// The Costs page's reporting-window toggle: the same cards over the last 7 or
/// the last 30 days.
///
/// Presentation-only — both windows are cut from the one cached 30-day scan
/// (`CostSummary.dailyCostWindow` / `CostChartPresentation.requestedDays`), so
/// switching never triggers a rescan; the 7-day view just renders a quarter of
/// the marks. The raw value *is* the day count, which is what
/// `UserDefaults` persists — an unknown stored count falls back to the month.
nonisolated enum CostWindowSelection: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }

    var days: Int { rawValue }

    /// Segment title in the window picker.
    var pickerLabel: String { "\(days) days" }

    /// Card subtitle naming the window ("Last 30 days"), shared by the estimate
    /// card and the Daily Details trailing caption so they cannot drift.
    var subtitle: String { "Last \(days) days" }

    /// Title of the spend-chart card ("30 Day Spend").
    var spendCardTitle: String { "\(days) Day Spend" }

    /// Calendar width used when hourly rows are unavailable. Old seven-day
    /// caches keep their existing two-week fallback; the month always keeps
    /// the existing six-week calendar.
    var fallbackActivityWeeks: Int {
        switch self {
        case .week: return 2
        case .month: return TokenActivityCalendar.defaultWeeks
        }
    }
}
