import Foundation

/// The calendar window every cost scan and 30-day chart shares.
///
/// Distinct from `ScanWindows` in `CostScanWindows.swift`: this decides *when*
/// the reporting period starts, that one carries the per-window accumulators.
/// Split out of `CostTracker` (audit C1d).
enum CostWindow {
    /// Days a full scan must request to guarantee coverage for every window the
    /// Costs page can show, including Month-to-Date read on the 31st of a
    /// 31-day month (issue #544).
    ///
    /// `CostWindowSelection.month` itself only ever needs 30 trailing days, but
    /// a scan run with exactly `days: 30` sets `cutoff` to "today minus 29
    /// days" — on 31 January that is 2 January, so the 1st is never read.
    /// `monthToDateCostWindow` then asks `dailyCostWindow` for 31 days and
    /// finds no row for the 1st: the cache is genuinely short by a day, not
    /// merely mis-windowed. One extra day of scan width closes that gap for
    /// every month, since no calendar month exceeds 31 days.
    nonisolated static let scanWindowDays = 31

    /// Inclusive calendar-day boundary shared by the scan and 30-day charts.
    /// `days: 30` means today plus the previous 29 local calendar days, not a
    /// rolling 720-hour interval that can spill into a 31st date bucket.
    nonisolated static func start(
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let normalizedDays = max(1, days)
        let today = calendar.startOfDay(for: now)
        return CalendarDayStep.day(today, offsetBy: -(normalizedDays - 1), calendar: calendar)
    }

    /// Midnight on the 1st of `now`'s local calendar month (issue #270). Takes
    /// `now`/`calendar` as parameters rather than caching a start date, so the
    /// boundary is recomputed on every call and rolls over at midnight on the
    /// 1st without a restart or rescan.
    nonisolated static func startOfCurrentMonth(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        var components = calendar.dateComponents([.year, .month], from: today)
        components.day = 1
        return calendar.date(from: components) ?? today
    }
}
