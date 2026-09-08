import MeterBarShared
import XCTest
@testable import MeterBar

/// Guards the dashboard chart's per-day, per-provider bucketing.
///
/// The chart shipped with a hardcoded three-provider order that predated Grok
/// and OpenRouter, so their rows were bucketed into nothing and their bars drew
/// empty — a silent zero, not an error. These tests pin the order to the
/// `ServiceType` enum so adding a sixth provider can never reintroduce that.
final class DailyUsageChartBucketingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func day(_ offset: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private func row(_ offset: Int, provider: ServiceType, tokens: Int) -> DailyTokenUsage {
        DailyTokenUsage(
            date: day(offset).addingTimeInterval(3600 * 5),
            provider: provider,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: Double(tokens) / 1000
        )
    }

    /// Every provider MeterBar tracks has to be able to draw. The order itself
    /// is `ServiceType.sortOrder`, which is already the app's stable provider
    /// ordering everywhere else.
    func testProviderOrderCoversEveryTrackedService() {
        XCTAssertEqual(
            DailyUsageChart.providerOrder,
            ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        )
        XCTAssertEqual(Set(DailyUsageChart.providerOrder), Set(ServiceType.allCases))
    }

    /// The regression itself: Grok and OpenRouter rows used to produce no
    /// segment, so a day made entirely of Grok usage rendered as a blank column.
    func testEveryProviderProducesASegment() throws {
        let rows = ServiceType.allCases.map { row(0, provider: $0, tokens: 1000) }
        let days = DailyUsageChart.buildDays(from: rows, daysToShow: 3, now: now, calendar: calendar)

        let today = try XCTUnwrap(days.last)
        XCTAssertEqual(Set(today.segments.map(\.provider)), Set(ServiceType.allCases))
        XCTAssertEqual(today.totalTokens, 5000)
    }

    func testWindowEndsOnTodayAndSpansTheRequestedDayCount() {
        let days = DailyUsageChart.buildDays(from: [], daysToShow: 30, now: now, calendar: calendar)

        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first?.date, day(-29))
        XCTAssertEqual(days.last?.date, day(0))
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06,
    /// so `startOfDay(now)` on that day returns 01:00 (00:00–01:00 does not
    /// exist). Building the 30-day window by stepping from that instant
    /// without re-normalizing every hop preserves 01:00 on every earlier day,
    /// so their bucket keys never match a real row's `startOfDay` and the
    /// chart renders 29 of 30 bars empty. The UTC fixture above cannot
    /// exercise this — UTC never observes DST.
    func testWindowSurvivesTheSantiagoMidnightTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let dstNow = ISO8601DateFormatter().date(from: "2026-09-06T13:00:00Z") ?? now

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let date = santiago.date(from: components) ?? dstNow
            return santiago.startOfDay(for: date)
        }

        XCTAssertEqual(santiago.component(.hour, from: exactDay(2026, 9, 6)), 1)

        let todayRow = DailyTokenUsage(
            date: exactDay(2026, 9, 6).addingTimeInterval(3600 * 3),
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1
        )
        let sixDaysAgoRow = DailyTokenUsage(
            date: exactDay(2026, 8, 31).addingTimeInterval(3600 * 5),
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1
        )

        let days = DailyUsageChart.buildDays(
            from: [todayRow, sixDaysAgoRow],
            daysToShow: 7,
            now: dstNow,
            calendar: santiago
        )

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.date, exactDay(2026, 8, 31))
        XCTAssertEqual(days.last?.date, exactDay(2026, 9, 6))
        XCTAssertEqual(days[0].cost, 1, accuracy: 0.000_001)
        XCTAssertEqual(days[6].cost, 1, accuracy: 0.000_001)
        XCTAssertEqual(days[1...5].map(\.cost), [0, 0, 0, 0, 0])
    }

    /// A provider with nothing that day gets no segment, so the stacked column
    /// does not draw a zero-height slab in its colour.
    func testProvidersWithoutUsageAreOmittedFromTheDay() {
        let days = DailyUsageChart.buildDays(
            from: [row(-1, provider: .grok, tokens: 42)],
            daysToShow: 3,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(days[1].segments.map(\.provider), [.grok])
        XCTAssertTrue(days[2].segments.isEmpty)
    }
}
