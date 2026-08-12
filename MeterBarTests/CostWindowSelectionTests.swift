import XCTest
@testable import MeterBar

/// The Costs page window toggle (7 vs 30 days). Pure value rules only — the
/// picker itself is a plain segmented control over `allCases`.
final class CostWindowSelectionTests: XCTestCase {
    func testRawValuesAreTheDayCounts() {
        XCTAssertEqual(CostWindowSelection.week.days, 7)
        XCTAssertEqual(CostWindowSelection.month.days, 30)
        XCTAssertEqual(CostWindowSelection.monthToDate.days, 0)
        XCTAssertEqual(CostWindowSelection(rawValue: 7), .week)
        XCTAssertEqual(CostWindowSelection(rawValue: 30), .month)
        XCTAssertEqual(CostWindowSelection(rawValue: -1), .monthToDate)
        XCTAssertNil(CostWindowSelection(rawValue: 14), "unknown persisted day counts must fall back, not crash")
    }

    func testPickerRunsShortWindowFirstThenCalendarMonth() {
        XCTAssertEqual(CostWindowSelection.allCases, [.week, .month, .monthToDate])
    }

    func testDisplayStringsNameTheWindow() {
        XCTAssertEqual(CostWindowSelection.week.pickerLabel, "7 days")
        XCTAssertEqual(CostWindowSelection.month.pickerLabel, "30 days")
        XCTAssertEqual(CostWindowSelection.monthToDate.pickerLabel, "This month")
        XCTAssertEqual(CostWindowSelection.week.subtitle, "Last 7 days")
        XCTAssertEqual(CostWindowSelection.month.subtitle, "Last 30 days")
        XCTAssertEqual(CostWindowSelection.monthToDate.subtitle, "Month to date")
        XCTAssertEqual(CostWindowSelection.week.spendCardTitle, "7 Day Spend")
        XCTAssertEqual(CostWindowSelection.month.spendCardTitle, "30 Day Spend")
        XCTAssertEqual(CostWindowSelection.monthToDate.spendCardTitle, "Month-to-Date Spend")
    }

    func testMonthToDateDayCountIsInclusiveOfTheFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        XCTAssertEqual(CostWindowSelection.monthToDate.dayCount(now: now, calendar: calendar), 12)
        XCTAssertEqual(
            calendar.startOfDay(for: CostWindowSelection.monthToDate.startDate(now: now, calendar: calendar)),
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))
        )
    }

    func testFallbackActivityWeeksCoverTheSelectedWindow() {
        // Old summaries without hourly rows keep the existing two-week fallback;
        // the month keeps the unchanged six-week calendar.
        XCTAssertEqual(CostWindowSelection.week.fallbackActivityWeeks, 2)
        XCTAssertEqual(CostWindowSelection.month.fallbackActivityWeeks, TokenActivityCalendar.defaultWeeks)
        XCTAssertEqual(CostWindowSelection.monthToDate.fallbackActivityWeeks, TokenActivityCalendar.defaultWeeks)
    }
}
