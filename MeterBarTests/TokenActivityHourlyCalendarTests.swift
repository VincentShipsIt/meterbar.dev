import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class TokenActivityHourlyCalendarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testNilHourlyUsageFallsBackToTheExistingTwoWeekCalendar() {
        let grid = TokenActivityGrid(
            summary: makeSummary(hourlyUsage: nil),
            windowSelection: .week,
            now: now,
            calendar: calendar
        )

        XCTAssertNil(grid.hourly)
        XCTAssertEqual(grid.daily?.weeks.count, 2)
    }

    func testEmptyHourlyUsageFallsBackToTheExistingTwoWeekCalendar() {
        let grid = TokenActivityGrid(
            summary: makeSummary(hourlyUsage: []),
            windowSelection: .week,
            now: now,
            calendar: calendar
        )

        XCTAssertNil(grid.hourly)
        XCTAssertEqual(grid.daily?.weeks.count, 2)
    }

    func testPartialHourlyUsageBuildsSevenOldestToNewestRowsAndTwentyFourColumns() {
        let hour = hour(daysAgo: 2, hour: 13)
        let grid = TokenActivityGrid(
            summary: makeSummary(hourlyUsage: [usage(date: hour, provider: .claudeCode, input: 40)]),
            windowSelection: .week,
            now: now,
            calendar: calendar
        )

        let hourly = try? XCTUnwrap(grid.hourly)
        XCTAssertEqual(hourly?.days.count, 7)
        XCTAssertTrue(hourly?.days.allSatisfy { $0.hours.count == 24 } ?? false)
        XCTAssertEqual(hourly?.days.last?.date, calendar.startOfDay(for: now))
        XCTAssertEqual(hourly?.days.first?.date, day(daysAgo: 6))
        XCTAssertEqual(hourly?.hour(at: hour)?.totalTokens, 40)
        XCTAssertEqual(hourly?.activeHours.count, 1)
        XCTAssertEqual(hourly?.coverageStartDate, day(daysAgo: 2))
        XCTAssertEqual(hourly?.coverageSummary, "3 days tracked")
    }

    func testFullHourlyUsageAggregatesProvidersInEveryCell() throws {
        let rows = (0..<7).flatMap { dayOffset in
            (0..<24).flatMap { hourValue in
                let date = hour(daysAgo: dayOffset, hour: hourValue)
                return [
                    usage(date: date, provider: .claudeCode, input: 10),
                    usage(date: date, provider: .codexCli, input: 5),
                ]
            }
        }
        let grid = TokenActivityGrid(
            summary: makeSummary(hourlyUsage: rows),
            windowSelection: .week,
            now: now,
            calendar: calendar
        )

        let hourly = try XCTUnwrap(grid.hourly)
        XCTAssertEqual(hourly.hours.count, 7 * 24)
        XCTAssertEqual(hourly.activeHours.count, 7 * 24)
        XCTAssertTrue(hourly.hours.allSatisfy { $0.totalTokens == 15 })
        XCTAssertTrue(hourly.hours.allSatisfy { $0.providers.map(\.provider) == [.claudeCode, .codexCli] })
        XCTAssertEqual(hourly.coverageSummary, "7 days tracked")
    }

    func testMonthSelectionKeepsTheExistingThirtyDayCalendar() {
        let grid = TokenActivityGrid(
            summary: makeSummary(hourlyUsage: [
                usage(date: hour(daysAgo: 0, hour: 1), provider: .claudeCode, input: 1),
            ]),
            windowSelection: .month,
            now: now,
            calendar: calendar
        )

        XCTAssertNil(grid.hourly)
        XCTAssertEqual(grid.daily?.weeks.count, TokenActivityCalendar.defaultWeeks)
    }

    private func makeSummary(hourlyUsage: [HourlyTokenUsage]?) -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: day(daysAgo: 6),
                    provider: .claudeCode,
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0
                ),
            ],
            hourlyUsage: hourlyUsage
        )
    }

    private func usage(
        date: Date,
        provider: ServiceType,
        input: Int
    ) -> HourlyTokenUsage {
        HourlyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0
        )
    }

    private func day(daysAgo: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    private func hour(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: day(daysAgo: daysAgo)) ?? now
    }
}
