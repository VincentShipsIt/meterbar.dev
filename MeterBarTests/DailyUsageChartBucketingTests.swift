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
