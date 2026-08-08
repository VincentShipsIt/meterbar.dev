import XCTest
@testable import MeterBar

/// The Costs page window toggle (7 vs 30 days). Pure value rules only — the
/// picker itself is a plain segmented control over `allCases`.
final class CostWindowSelectionTests: XCTestCase {
    func testRawValuesAreTheDayCounts() {
        XCTAssertEqual(CostWindowSelection.week.days, 7)
        XCTAssertEqual(CostWindowSelection.month.days, 30)
        XCTAssertEqual(CostWindowSelection(rawValue: 7), .week)
        XCTAssertEqual(CostWindowSelection(rawValue: 30), .month)
        XCTAssertNil(CostWindowSelection(rawValue: 14), "unknown persisted day counts must fall back, not crash")
    }

    func testPickerRunsShortWindowFirst() {
        XCTAssertEqual(CostWindowSelection.allCases, [.week, .month])
    }

    func testDisplayStringsNameTheWindow() {
        XCTAssertEqual(CostWindowSelection.week.pickerLabel, "7 days")
        XCTAssertEqual(CostWindowSelection.month.pickerLabel, "30 days")
        XCTAssertEqual(CostWindowSelection.week.subtitle, "Last 7 days")
        XCTAssertEqual(CostWindowSelection.month.subtitle, "Last 30 days")
        XCTAssertEqual(CostWindowSelection.week.spendCardTitle, "7 Day Spend")
        XCTAssertEqual(CostWindowSelection.month.spendCardTitle, "30 Day Spend")
    }

    func testActivityWeeksCoverTheSelectedWindow() {
        // Two 7-day columns are the narrowest grid that always spans the last
        // 7 days; the month keeps the existing six-week calendar.
        XCTAssertEqual(CostWindowSelection.week.activityWeeks, 2)
        XCTAssertEqual(CostWindowSelection.month.activityWeeks, TokenActivityCalendar.defaultWeeks)
    }
}
