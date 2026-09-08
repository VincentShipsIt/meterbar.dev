import XCTest
@testable import MeterBar

/// Direct coverage for the day-stepping primitive behind issue #532.
///
/// `Calendar.date(byAdding: .day, ...)` preserves wall-clock time, not the day
/// boundary. In zones whose DST transition happens *at* local midnight, the
/// 00:00–01:00 hour does not exist on the transition day, so
/// `calendar.startOfDay(for:)` returns 01:00 that day. A raw `byAdding` step
/// from that 01:00 instant lands on 01:00 on every other (non-transition) day
/// too, which never equals that day's own `startOfDay`.
///
/// `America/Los_Angeles`, `Europe/London` and UTC do not exhibit this — their
/// transitions sit at 01:00/02:00 local, so `startOfDay` is always midnight —
/// which is exactly why every prior test pinned to one of those zones passed
/// with the bug still in place. These pin zones whose transition is
/// confirmed to fall at midnight instead.
final class CalendarDayStepTests: XCTestCase {
    private func zone(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    // MARK: - America/Santiago (confirmed case, 2026-09-06)

    /// Establishes the repro premise: on the transition day itself,
    /// `startOfDay` is not midnight. If this ever stops being true (tzdata
    /// changes Chile's transition rule), the rest of this test would be
    /// exercising a day that no longer reproduces the bug.
    func testSantiagoStartOfDayOnTheTransitionDayIsNotMidnight() {
        let santiago = zone("America/Santiago")
        // 2026-09-06T13:00:00Z = 10:00 local, well after the 01:00 jump.
        let now = date("2026-09-06T13:00:00Z")

        let startOfDay = santiago.startOfDay(for: now)

        XCTAssertEqual(santiago.component(.hour, from: startOfDay), 1)
        XCTAssertEqual(santiago.component(.day, from: startOfDay), 6)
    }

    /// The fix itself: stepping backward from that 01:00 instant must still
    /// land on the exact midnight of every earlier day, matching
    /// `startOfDay` computed directly for that day rather than drifting to
    /// 01:00 everywhere.
    func testDayOffsetRenormalizesAcrossTheSantiagoMidnightTransition() {
        let santiago = zone("America/Santiago")
        let today = santiago.startOfDay(for: date("2026-09-06T13:00:00Z"))

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let value = santiago.date(from: components) ?? today
            return santiago.startOfDay(for: value)
        }

        // Every expected date is computed independently via explicit
        // `DateComponents`, not derived from `CalendarDayStep` itself, so this
        // cannot pass by tautology. Offset 0 is the transition day itself —
        // its real `startOfDay` legitimately is 01:00; every other offset
        // must land on an ordinary midnight.
        let expectations: [(offset: Int, day: Date, hour: Int)] = [
            (-29, exactDay(2026, 8, 8), 0),
            (-7, exactDay(2026, 8, 30), 0),
            (-6, exactDay(2026, 8, 31), 0),
            (-1, exactDay(2026, 9, 5), 0),
            (0, exactDay(2026, 9, 6), 1),
            (1, exactDay(2026, 9, 7), 0),
        ]

        for (offset, expectedDay, expectedHour) in expectations {
            let stepped = CalendarDayStep.day(today, offsetBy: offset, calendar: santiago)

            XCTAssertEqual(stepped, expectedDay, "offset \(offset) must land on the exact day boundary")
            XCTAssertEqual(
                santiago.component(.hour, from: stepped),
                expectedHour,
                "offset \(offset) must not carry the transition day's 01:00 wall clock onto another day"
            )
        }
    }

    /// A raw, un-renormalized step is the bug this type exists to prevent:
    /// demonstrate the failure mode directly so the fix's necessity stays
    /// provable even if `CalendarDayStep` itself regresses.
    func testRawByAddingWithoutRenormalizationWouldMismatchStartOfDay() {
        let santiago = zone("America/Santiago")
        let today = santiago.startOfDay(for: date("2026-09-06T13:00:00Z"))
        let sixDaysBack = santiago.date(byAdding: .day, value: -6, to: today) ?? today

        let trueStartOfThatDay = santiago.startOfDay(for: sixDaysBack)

        XCTAssertNotEqual(sixDaysBack, trueStartOfThatDay)
        // The renormalized helper does not share this defect.
        XCTAssertEqual(CalendarDayStep.day(today, offsetBy: -6, calendar: santiago), trueStartOfThatDay)
    }

    // MARK: - America/Havana (confirmed case, 2026-03-08) and Asia/Beirut (2026-03-29)

    func testDayOffsetRenormalizesAcrossTheHavanaMidnightTransition() {
        let havana = zone("America/Havana")
        // 2026-03-08T16:00:00Z = 11:00 local, after the 01:00 jump.
        let today = havana.startOfDay(for: date("2026-03-08T16:00:00Z"))
        XCTAssertEqual(havana.component(.hour, from: today), 1)

        let weekAgo = CalendarDayStep.day(today, offsetBy: -7, calendar: havana)

        XCTAssertEqual(havana.component(.hour, from: weekAgo), 0)
        XCTAssertEqual(weekAgo, havana.startOfDay(for: weekAgo))
    }

    func testDayOffsetRenormalizesAcrossTheBeirutMidnightTransition() {
        let beirut = zone("Asia/Beirut")
        // 2026-03-29T09:00:00Z = 12:00 local, after the 01:00 jump.
        let today = beirut.startOfDay(for: date("2026-03-29T09:00:00Z"))
        XCTAssertEqual(beirut.component(.hour, from: today), 1)

        let weekAgo = CalendarDayStep.day(today, offsetBy: -7, calendar: beirut)

        XCTAssertEqual(beirut.component(.hour, from: weekAgo), 0)
        XCTAssertEqual(weekAgo, beirut.startOfDay(for: weekAgo))
    }

    // MARK: - Non-DST path stays valid

    /// UTC never observes DST, so this pins the ordinary path the bug never
    /// touched — it stays covered, it just isn't proof of the fix.
    func testDayOffsetInUTCIsUnaffected() {
        let utc = zone("UTC")
        let today = utc.startOfDay(for: date("2026-06-15T12:00:00Z"))

        XCTAssertEqual(CalendarDayStep.day(today, offsetBy: -30, calendar: utc), date("2026-05-16T00:00:00Z"))
        XCTAssertEqual(CalendarDayStep.day(today, offsetBy: 1, calendar: utc), date("2026-06-16T00:00:00Z"))
    }
}
