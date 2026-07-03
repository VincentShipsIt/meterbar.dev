import XCTest
import MeterBarShared
@testable import MeterBar

/// Unit tests for `CostSummary.dailyCostWindow` — the pure filter behind
/// `meterbar cost --days N` (issue #26). Uses a fixed `now` + UTC calendar so
/// day-boundary math is deterministic.
final class CostWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A daily row `offset` days before `now` (0 = today).
    private func row(
        daysAgo offset: Int,
        provider: ServiceType,
        input: Int,
        output: Int,
        cacheRead: Int,
        cost: Double
    ) -> DailyTokenUsage {
        let today = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        return DailyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost
        )
    }

    private func summary(dailyUsage: [DailyTokenUsage], periodDays: Int) -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: periodDays,
            dailyUsage: dailyUsage
        )
    }

    // MARK: - Window boundary

    func testKeepsOnlyRowsInsideTheWindow() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 10, output: 5, cacheRead: 1, cost: 1.0),
                row(daysAgo: 2, provider: .claudeCode, input: 20, output: 5, cacheRead: 1, cost: 2.0),
                row(daysAgo: 3, provider: .claudeCode, input: 99, output: 99, cacheRead: 99, cost: 9.0),
                row(daysAgo: 4, provider: .claudeCode, input: 99, output: 99, cacheRead: 99, cost: 9.0)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 3, now: now, calendar: calendar)

        // Only offsets 0..2 fall in a 3-day window (today + 2 prior days).
        let claude = window.providers.first { $0.provider == .claudeCode }
        XCTAssertEqual(window.providers.count, 1)
        XCTAssertEqual(claude?.inputTokens, 30)
        XCTAssertEqual(claude?.outputTokens, 10)
        XCTAssertEqual(claude?.cacheReadTokens, 2)
        XCTAssertEqual(claude?.estimatedCostUSD, 3.0)
        XCTAssertEqual(window.totalCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertEqual(window.totalTokens, 42)
        XCTAssertFalse(window.isTruncated)
    }

    // MARK: - Aggregation across providers

    func testAggregatesPerProviderSortedByRawValue() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1.0),
                row(daysAgo: 1, provider: .claudeCode, input: 5, output: 0, cacheRead: 0, cost: 0.5),
                row(daysAgo: 0, provider: .codexCli, input: 7, output: 0, cacheRead: 0, cost: 0.7)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertEqual(window.providers.count, 2)
        XCTAssertEqual(window.providers.map(\.provider), [.claudeCode, .codexCli])
        XCTAssertEqual(window.providers[0].inputTokens, 15)
        XCTAssertEqual(window.providers[1].inputTokens, 7)
    }

    // MARK: - Truncation notice

    func testFlagsTruncationWhenCacheSpansFewerDays() {
        let summary = summary(
            dailyUsage: [row(daysAgo: 0, provider: .claudeCode, input: 1, output: 1, cacheRead: 0, cost: 0.1)],
            periodDays: 2
        )

        let window = summary.dailyCostWindow(lastDays: 30, now: now, calendar: calendar)

        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.requestedDays, 30)
        XCTAssertEqual(window.coveredDays, 2)
    }

    // MARK: - Clamping

    func testClampsNonPositiveDaysToOne() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 3, output: 0, cacheRead: 0, cost: 0.3),
                row(daysAgo: 1, provider: .claudeCode, input: 9, output: 0, cacheRead: 0, cost: 0.9)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 0, now: now, calendar: calendar)

        // Clamped to a single day (today only) → excludes yesterday's 9.
        XCTAssertEqual(window.requestedDays, 1)
        XCTAssertEqual(window.providers.first?.inputTokens, 3)
    }
}
