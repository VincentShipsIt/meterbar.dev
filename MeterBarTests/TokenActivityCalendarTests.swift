import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers the pure geometry, aggregation, coverage and banding math behind the
/// `Token Activity` contribution calendar.
///
/// Everything asserted here runs without a rendered view: the card only draws
/// what `TokenActivityCalendar` already decided, so grid alignment, future-date
/// suppression, known-zero vs unavailable days, and outlier-resistant intensity
/// bands are all provable from this harness.
final class TokenActivityCalendarTests: XCTestCase {
    /// Sunday, 2025-06-15 in UTC — a week boundary under `firstWeekday == 1`
    /// and the last weekday of the week under `firstWeekday == 2`, so the same
    /// instant exercises both a one-day and a full trailing week.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    private var mondayFirstCalendar: Calendar {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        return mondayFirst
    }

    // MARK: - Grid geometry

    func testTrailingGridIsAMonthOfSevenWeekdaySlots() {
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)

        XCTAssertEqual(TokenActivityCalendar.defaultWeeks, 6)
        // Six columns is the smallest window that always spans the 30 days the
        // rest of the dashboard reports: five would bottom out at 29 when today
        // is the first weekday of its column, clipping a day off the scan.
        XCTAssertGreaterThanOrEqual(activity.days.count, 30)
        XCTAssertEqual(activity.weeks.count, TokenActivityCalendar.defaultWeeks)
        XCTAssertTrue(activity.weeks.allSatisfy { $0.days.count == 7 })
        XCTAssertEqual(activity.weeks.map(\.index), Array(0..<TokenActivityCalendar.defaultWeeks))
    }

    func testEveryColumnStartsOnTheCalendarsFirstWeekday() {
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)

        for week in activity.weeks {
            XCTAssertEqual(calendar.component(.weekday, from: week.startDate), calendar.firstWeekday)
        }

        // Row N is always the same weekday, which is what makes the grid readable.
        for row in 0..<7 {
            let weekdays = activity.weeks.compactMap { $0.days[row]?.date }
                .map { calendar.component(.weekday, from: $0) }
            XCTAssertEqual(Set(weekdays).count, 1, "row \(row) mixed weekdays")
        }
    }

    func testGridEndsOnTodayAndLeavesFutureCellsEmpty() {
        let today = calendar.startOfDay(for: now)
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)

        // Sunday-first: today is Sunday, so the current column holds a single day.
        XCTAssertEqual(activity.weeks.last?.days.first??.date, today)
        XCTAssertEqual(activity.weeks.last?.days.dropFirst().compactMap { $0 }.count, 0)
        XCTAssertEqual(activity.endDate, today)
        XCTAssertNil(activity.days.first { $0.date > today })
        XCTAssertEqual(activity.days.count, (TokenActivityCalendar.defaultWeeks - 1) * 7 + 1)
    }

    func testGridHonoursAMondayFirstCalendar() {
        let mondayFirst = mondayFirstCalendar
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: mondayFirst)

        // Today is a Sunday, the final slot of a Monday-first week: no gaps at all.
        XCTAssertEqual(activity.weeks.last?.days.compactMap { $0 }.count, 7)
        XCTAssertEqual(activity.weeks.last?.days.last??.date, mondayFirst.startOfDay(for: now))
        XCTAssertEqual(activity.days.count, TokenActivityCalendar.defaultWeeks * 7)
        XCTAssertEqual(mondayFirst.component(.weekday, from: activity.startDate), 2)
    }

    func testDaysAreContiguousAndStrictlyIncreasing() {
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)
        let dates = activity.days.map(\.date)

        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
        for (previous, next) in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: previous, to: next).day, 1)
        }
    }

    func testRequestedWeeksAreClampedToASensibleRange() {
        let tiny = TokenActivityCalendar(summary: makeSummary(), weeks: 0, now: now, calendar: calendar)
        let huge = TokenActivityCalendar(summary: makeSummary(), weeks: 500, now: now, calendar: calendar)

        XCTAssertEqual(tiny.weeks.count, 1)
        // The ceiling is its own constant: while it was the default too,
        // narrowing the visible window would have silently capped every caller
        // that asks for a longer one.
        XCTAssertEqual(huge.weeks.count, TokenActivityCalendar.maxWeeks)
        XCTAssertGreaterThan(TokenActivityCalendar.maxWeeks, TokenActivityCalendar.defaultWeeks)
    }

    // MARK: - Month labels

    func testMonthLabelsAppearOncePerMonthChangeInWeekOrder() {
        let activity = TokenActivityCalendar(
            summary: makeSummary(),
            weeks: TokenActivityCalendar.maxWeeks,
            now: now,
            calendar: calendar
        )
        let labels = activity.monthLabels

        XCTAssertEqual(labels.map(\.weekIndex), labels.map(\.weekIndex).sorted())
        XCTAssertEqual(Set(labels.map(\.weekIndex)).count, labels.count)
        XCTAssertEqual(labels.count, 12, "a 53-week window changes month twelve times")
        XCTAssertFalse(labels.contains { $0.weekIndex == 0 }, "the leading partial month stays unlabelled")
        XCTAssertFalse(labels.contains { $0.title.isEmpty })
        XCTAssertEqual(labels.last?.title, "Jun")
    }

    func testDefaultMonthWindowStillLabelsItsMonthChange() {
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)

        // Six columns back from Sunday 2025-06-15 open on May 11, so the window
        // straddles exactly one boundary. A month view that labelled nothing
        // would leave the header row blank.
        XCTAssertEqual(activity.monthLabels.map(\.title), ["Jun"])
    }

    func testMonthLabelsSurviveTheYearBoundary() {
        let newYear = Date(timeIntervalSince1970: 1_767_700_000) // 2026-01-06
        let activity = TokenActivityCalendar(summary: makeSummary(), weeks: 8, now: newYear, calendar: calendar)

        let titles = activity.monthLabels.map(\.title)
        XCTAssertTrue(titles.contains("Dec"), "December label missing: \(titles)")
        XCTAssertTrue(titles.contains("Jan"), "January label missing: \(titles)")
        XCTAssertEqual(activity.days.map(\.date), activity.days.map(\.date).sorted())
    }

    // MARK: - Aggregation

    func testSameDayProviderRowsAggregateIntoOneCell() {
        let today = calendar.startOfDay(for: now)
        let midday = calendar.date(byAdding: .hour, value: 13, to: today) ?? today
        let summary = makeSummary(dailyUsage: [
            usage(date: today, provider: .claudeCode, input: 300, output: 100, cacheRead: 200, cost: 2),
            usage(date: midday, provider: .claudeCode, input: 100, output: 0, cacheRead: 0, cost: 1),
            usage(date: today, provider: .codexCli, input: 50, output: 25, cacheRead: 0, cost: 0.5),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)
        let cell = try? XCTUnwrap(activity.days.last)

        XCTAssertEqual(cell?.totalTokens, 775)
        XCTAssertEqual(cell?.estimatedCostUSD ?? 0, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(cell?.providers.map(\.provider), [.claudeCode, .codexCli], "biggest provider leads")
        XCTAssertEqual(cell?.providers.first?.tokens, 700)
        XCTAssertEqual(cell?.providers.last?.tokens, 75)
    }

    func testTotalsIgnoreNegativeRows() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 0, provider: .claudeCode, input: -500, output: -10, cacheRead: 0, cost: -4),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.totalTokens, 0)
        XCTAssertEqual(activity.totalCostUSD, 0, accuracy: 0.000_001)
        XCTAssertTrue(activity.activeDays.isEmpty)
        XCTAssertEqual(activity.days.last?.level, 0)
    }

    func testRowsOlderThanTheGridAreExcluded() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 400, provider: .claudeCode, input: 9_999, output: 0, cacheRead: 0, cost: 99),
            usage(daysAgo: 0, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.totalTokens, 10)
        XCTAssertEqual(activity.activeDays.count, 1)
    }

    // MARK: - Coverage

    func testConfirmedZeroDaysAreDistinctFromUnavailableHistory() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 2, provider: .claudeCode, input: 100, output: 0, cacheRead: 0, cost: 1),
            usage(daysAgo: 0, provider: .claudeCode, input: 200, output: 0, cacheRead: 0, cost: 2),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.coverageStartDate, day(daysAgo: 2))
        XCTAssertEqual(activity.trackedDays.count, 3)

        let quietDay = activity.days.first { $0.date == day(daysAgo: 1) }
        XCTAssertEqual(quietDay?.isCovered, true)
        XCTAssertEqual(quietDay?.totalTokens, 0)
        XCTAssertEqual(quietDay?.level, 0)

        let unknownDay = activity.days.first { $0.date == day(daysAgo: 3) }
        XCTAssertEqual(unknownDay?.isCovered, false)
        XCTAssertEqual(unknownDay?.totalTokens, 0)

        XCTAssertEqual(activity.days.filter { !$0.isCovered }.count, activity.days.count - 3)
    }

    func testFutureDatedRowsNeverExtendCoverage() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let summary = makeSummary(dailyUsage: [
            usage(date: tomorrow, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1),
            usage(daysAgo: 1, provider: .claudeCode, input: 20, output: 0, cacheRead: 0, cost: 2),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.coverageStartDate, day(daysAgo: 1))
        XCTAssertEqual(activity.trackedDays.count, 2)
        XCTAssertEqual(activity.totalTokens, 20)
    }

    func testEmptyHistoryProducesNoCoverageAndNoFabricatedZeros() {
        let activity = TokenActivityCalendar(summary: makeSummary(), now: now, calendar: calendar)

        XCTAssertFalse(activity.hasHistory)
        XCTAssertNil(activity.coverageStartDate)
        XCTAssertTrue(activity.trackedDays.isEmpty)
        XCTAssertTrue(activity.activeDays.isEmpty)
        XCTAssertTrue(activity.days.allSatisfy { !$0.isCovered })
        XCTAssertNil(activity.coverageSummary)
    }

    func testMissingSummaryBehavesLikeEmptyHistory() {
        let activity = TokenActivityCalendar(summary: nil, now: now, calendar: calendar)

        XCTAssertFalse(activity.hasHistory)
        XCTAssertEqual(activity.weeks.count, TokenActivityCalendar.defaultWeeks)
        XCTAssertTrue(activity.days.allSatisfy { !$0.isCovered })
    }

    func testCoverageSummaryNamesTheFirstTrackedDay() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 4, provider: .codexCli, input: 10, output: 0, cacheRead: 0, cost: 1),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.coverageSummary, "5 days tracked")
    }

    // MARK: - Intensity bands

    func testZeroTokensAlwaysLandOnTheEmptyBand() {
        let scale = TokenActivityIntensityScale(dailyTotals: [10, 20, 30, 40])

        XCTAssertEqual(scale.level(for: 0), 0)
        XCTAssertEqual(scale.level(for: -5), 0)
        XCTAssertGreaterThanOrEqual(scale.level(for: 1), 1)
    }

    func testBandsStayGraduatedWhenOneDayDwarfsTheRest() {
        let ordinary = Array(1...20).map { $0 * 1_000 }
        let scale = TokenActivityIntensityScale(dailyTotals: ordinary + [10_000_000])

        let ordinaryLevels = Set(ordinary.map { scale.level(for: $0) })
        XCTAssertGreaterThanOrEqual(
            ordinaryLevels.count,
            3,
            "a single outlier must not flatten the rest of the range into one band"
        )
        XCTAssertEqual(scale.level(for: 10_000_000), TokenActivityIntensityScale.bandCount)
        XCTAssertEqual(scale.level(for: 1_000), 1)
        XCTAssertGreaterThan(scale.level(for: 20_000), scale.level(for: 1_000))
    }

    func testLevelsAreMonotonicInTokenCount() {
        let totals = [5, 12, 90, 400, 400, 7_000, 88_000, 1_000_000]
        let scale = TokenActivityIntensityScale(dailyTotals: totals)

        let levels = totals.sorted().map { scale.level(for: $0) }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(scale.level(for: totals.max() ?? 0), scale.usedBandCount)
    }

    func testUniformHistoryUsesASingleQuietBand() {
        let scale = TokenActivityIntensityScale(dailyTotals: [500, 500, 500, 500])

        XCTAssertEqual(scale.usedBandCount, 1)
        XCTAssertEqual(scale.level(for: 500), 1)
    }

    func testTwoDistinctTotalsUseTwoBands() {
        let scale = TokenActivityIntensityScale(dailyTotals: [100, 100, 900])

        XCTAssertEqual(scale.usedBandCount, 2)
        XCTAssertEqual(scale.level(for: 100), 1)
        XCTAssertEqual(scale.level(for: 900), 2)
    }

    func testEmptyHistoryScaleStillClassifiesUsage() {
        let scale = TokenActivityIntensityScale(dailyTotals: [])

        XCTAssertEqual(scale.usedBandCount, 0)
        XCTAssertEqual(scale.level(for: 0), 0)
        XCTAssertEqual(scale.level(for: 5), 1)
    }

    func testCalendarAssignsTheTopBandToItsBusiestDay() {
        let summary = makeSummary(dailyUsage: (0..<8).map { offset in
            usage(
                daysAgo: offset,
                provider: .claudeCode,
                input: (offset + 1) * 1_000,
                output: 0,
                cacheRead: 0,
                cost: Double(offset + 1)
            )
        })

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)
        let busiest = activity.activeDays.max { $0.totalTokens < $1.totalTokens }

        XCTAssertEqual(busiest?.level, TokenActivityIntensityScale.bandCount)
        XCTAssertEqual(activity.activeDays.count, 8)
        XCTAssertEqual(Set(activity.activeDays.map(\.level)).count, TokenActivityIntensityScale.bandCount)
    }

    // MARK: - Time zones

    func testGridSurvivesADaylightSavingTransition() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        losAngeles.locale = Locale(identifier: "en_US_POSIX")
        losAngeles.firstWeekday = 1
        let formatter = ISO8601DateFormatter()
        let dstNow = formatter.date(from: "2026-03-09T12:00:00Z") ?? now

        let activity = TokenActivityCalendar(summary: makeSummary(), weeks: 4, now: dstNow, calendar: losAngeles)
        let dates = activity.days.map(\.date)

        XCTAssertTrue(activity.weeks.allSatisfy { $0.days.count == 7 })
        XCTAssertTrue(dates.allSatisfy { losAngeles.startOfDay(for: $0) == $0 })
        for (previous, next) in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(losAngeles.dateComponents([.day], from: previous, to: next).day, 1)
        }
        XCTAssertEqual(activity.endDate, losAngeles.startOfDay(for: dstNow))
    }

    func testDaysAreGroupedInTheSuppliedTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        tokyo.locale = Locale(identifier: "en_US_POSIX")
        tokyo.firstWeekday = 1
        let formatter = ISO8601DateFormatter()
        // 22:00 UTC is already the next calendar day in Tokyo.
        let lateUTC = formatter.date(from: "2025-06-14T22:00:00Z") ?? now
        let summary = makeSummary(dailyUsage: [
            usage(date: lateUTC, provider: .claudeCode, input: 42, output: 0, cacheRead: 0, cost: 1),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: tokyo)

        XCTAssertEqual(activity.activeDays.count, 1)
        XCTAssertEqual(activity.activeDays.first?.date, tokyo.startOfDay(for: lateUTC))
        XCTAssertEqual(tokyo.component(.day, from: activity.activeDays.first?.date ?? now), 15)
    }

    // MARK: - Accessibility and tooltips

    func testTrackedDayDescribesTokensCostAndProviders() {
        let today = calendar.startOfDay(for: now)
        let summary = makeSummary(dailyUsage: [
            usage(date: today, provider: .claudeCode, input: 1_000_000, output: 200_000, cacheRead: 0, cost: 12.5),
            usage(date: today, provider: .codexCli, input: 300_000, output: 0, cacheRead: 0, cost: 4),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)
        let cell = activity.days.last

        XCTAssertEqual(cell?.accessibilityLabel, DashboardDateFormat.medium(today))
        let value = cell?.accessibilityValue ?? ""
        XCTAssertTrue(value.contains("1.5M tokens"), value)
        XCTAssertTrue(value.contains("$16.50"), value)
        XCTAssertTrue(value.contains(ServiceType.claudeCode.displayName), value)
        XCTAssertTrue(value.contains(ServiceType.codexCli.displayName), value)
        XCTAssertTrue(value.contains("intensity"), "non-colour intensity must be spoken: \(value)")

        let tooltip = cell?.tooltip ?? ""
        XCTAssertTrue(tooltip.hasPrefix(DashboardDateFormat.medium(today)), tooltip)
        XCTAssertTrue(tooltip.contains("$16.50"), tooltip)
        XCTAssertTrue(tooltip.contains(ServiceType.codexCli.displayName), tooltip)
    }

    func testQuietAndUnknownDaysReadDifferently() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 1, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)
        let quiet = activity.days.first { $0.date == day(daysAgo: 0) }
        let unknown = activity.days.first { $0.date == day(daysAgo: 5) }

        XCTAssertEqual(quiet?.accessibilityValue, "No tracked usage")
        XCTAssertEqual(unknown?.accessibilityValue, "No retained history")
        XCTAssertNotEqual(quiet?.accessibilityValue, unknown?.accessibilityValue)
        XCTAssertTrue(unknown?.tooltip.contains("No retained history") ?? false)
    }

    func testWeekdaySymbolsFollowTheCalendarsFirstWeekday() {
        let sundayFirst = TokenActivityCalendar(summary: makeSummary(), weeks: 4, now: now, calendar: calendar)
        let mondayFirst = TokenActivityCalendar(
            summary: makeSummary(),
            weeks: 4,
            now: now,
            calendar: mondayFirstCalendar
        )

        XCTAssertEqual(sundayFirst.weekdaySymbols.count, 7)
        XCTAssertEqual(sundayFirst.weekdaySymbols.first, calendar.shortWeekdaySymbols.first)
        XCTAssertEqual(mondayFirst.weekdaySymbols.first, calendar.shortWeekdaySymbols[1])
        XCTAssertEqual(mondayFirst.weekdaySymbols.last, calendar.shortWeekdaySymbols[0])
    }

    // MARK: - Hover / focus detail

    func testDetailLineNamesTheDateTokensCostAndProviders() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 2, provider: .claudeCode, input: 1_000_000, output: 400_000, cacheRead: 100_000, cost: 16.5),
            usage(daysAgo: 2, provider: .codexCli, input: 20_000, output: 0, cacheRead: 0, cost: 0.5),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)
        let detail = activity.day(on: day(daysAgo: 2))?.detailLine ?? ""

        XCTAssertTrue(detail.contains(DashboardDateFormat.medium(day(daysAgo: 2))))
        XCTAssertTrue(detail.contains("1.5M tokens"))
        XCTAssertTrue(detail.contains("$17.00"))
        XCTAssertTrue(detail.contains(ServiceType.claudeCode.displayName))
        XCTAssertTrue(detail.contains(ServiceType.codexCli.displayName))
        XCTAssertFalse(detail.contains("\n"), "the detail line sits on a single row under the grid")
    }

    func testDetailLineDistinguishesQuietDaysFromUnavailableDays() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 3, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(activity.day(on: day(daysAgo: 0))?.detailLine.hasSuffix("No tracked usage"), true)
        XCTAssertEqual(activity.day(on: day(daysAgo: 9))?.detailLine.hasSuffix("No retained history"), true)
    }

    func testDayLookupOnlyResolvesRenderedCells() {
        let activity = TokenActivityCalendar(summary: makeSummary(), weeks: 4, now: now, calendar: calendar)

        XCTAssertNotNil(activity.day(on: day(daysAgo: 0)))
        XCTAssertNil(activity.day(on: day(daysAgo: -1)), "tomorrow has no cell")
        XCTAssertNil(activity.day(on: day(daysAgo: 400)), "dates before the grid have no cell")
    }

    func testOverviewLineSummarisesTheWindowAndItsBusiestDay() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 1, provider: .claudeCode, input: 1_000_000, output: 0, cacheRead: 0, cost: 10),
            usage(daysAgo: 4, provider: .codexCli, input: 500_000, output: 0, cacheRead: 0, cost: 5),
        ])

        let overview = TokenActivityCalendar(summary: summary, now: now, calendar: calendar).overviewLine

        XCTAssertTrue(overview.contains("1.5M tokens"))
        XCTAssertTrue(overview.contains("$15.00"))
        XCTAssertTrue(overview.contains(DashboardDateFormat.medium(day(daysAgo: 1))), "names the busiest day")
    }

    func testOverviewLineReportsATrackedButQuietWindow() {
        let summary = makeSummary(dailyUsage: [
            usage(daysAgo: 2, provider: .claudeCode, input: 0, output: 0, cacheRead: 0, cost: 0),
        ])

        let activity = TokenActivityCalendar(summary: summary, now: now, calendar: calendar)

        XCTAssertTrue(activity.hasHistory)
        XCTAssertFalse(activity.hasActivity)
        XCTAssertEqual(activity.overviewLine, "No tracked usage in this window.")
    }

    // MARK: - Fixtures

    private func makeSummary(
        dailyUsage: [DailyTokenUsage] = [],
        periodDays: Int = 30
    ) -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: periodDays,
            dailyUsage: dailyUsage
        )
    }

    private func day(daysAgo: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    private func usage(
        daysAgo: Int,
        provider: ServiceType,
        input: Int,
        output: Int,
        cacheRead: Int,
        cost: Double
    ) -> DailyTokenUsage {
        usage(
            date: day(daysAgo: daysAgo),
            provider: provider,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cost: cost
        )
    }

    private func usage(
        date: Date,
        provider: ServiceType,
        input: Int,
        output: Int,
        cacheRead: Int,
        cost: Double
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost
        )
    }
}
