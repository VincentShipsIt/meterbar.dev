import Foundation

/// Shared day-stepping arithmetic for every calendar-bucketed chart, window,
/// and cache in MeterBar.
///
/// `Calendar.date(byAdding: .day, ...)` preserves wall-clock time, not the day
/// boundary. In zones whose DST transition happens *at* midnight (e.g.
/// `America/Santiago`), the 00:00–01:00 hour does not exist on the transition
/// day, so `calendar.startOfDay(for: now)` returns 01:00 instead of 00:00. A
/// raw `byAdding` step from that 01:00 instant preserves 01:00 on every other,
/// non-transition day — which never equals `calendar.startOfDay(for:)` of that
/// day. Every date-keyed bucket lookup, `>=`/`==` window bound, and dictionary
/// grouping in this codebase keys off `startOfDay`, so an un-renormalized step
/// silently misses its own bucket (`TokenActivityCalendar.day(_:offsetBy:)`
/// documented and fixed this first; this type generalizes it so every other
/// call site can share the fix instead of re-deriving it).
///
/// Always pass an already-day-normalized `date` (typically
/// `calendar.startOfDay(for: now)`, or a previous `CalendarDayStep.day`
/// result); the result is re-normalized after the step so every hop lands on
/// an exact day boundary regardless of the zone.
enum CalendarDayStep {
    static func day(_ date: Date, offsetBy days: Int, calendar: Calendar) -> Date {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return date }
        return calendar.startOfDay(for: shifted)
    }
}
