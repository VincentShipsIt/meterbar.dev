import Foundation

/// The calendar window every cost scan and 30-day chart shares.
///
/// Distinct from `ScanWindows` in `CostScanWindows.swift`: this decides *when*
/// the reporting period starts, that one carries the per-window accumulators.
/// Split out of `CostTracker` (audit C1d).
enum CostWindow {
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
        return calendar.date(
            byAdding: .day,
            value: -(normalizedDays - 1),
            to: today
        ) ?? today
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
