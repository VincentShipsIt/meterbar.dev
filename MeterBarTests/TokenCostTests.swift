import XCTest
@testable import MeterBar

final class TokenCostTests: XCTestCase {
    // MARK: - TokenCost Tests

    func testTotalTokensCalculation() {
        let cost = makeTokenCost(
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 200,
            cacheReadTokens: 100
        )
        XCTAssertEqual(cost.totalTokens, 1800)
    }

    func testTotalTokensWithZeroValues() {
        let cost = makeTokenCost(
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        XCTAssertEqual(cost.totalTokens, 0)
    }

    func testFormattedCost() {
        let cost1 = makeTokenCost(estimatedCostUSD: 1.50)
        XCTAssertEqual(cost1.formattedCost, "$1.50")

        let cost2 = makeTokenCost(estimatedCostUSD: 0.05)
        XCTAssertEqual(cost2.formattedCost, "$0.05")

        let cost3 = makeTokenCost(estimatedCostUSD: 123.456)
        XCTAssertEqual(cost3.formattedCost, "$123.46")

        let cost4 = makeTokenCost(estimatedCostUSD: 8_385.09)
        XCTAssertEqual(cost4.formattedCost, "$8,385.09")
    }

    func testFormattedTokens() {
        let cost = makeTokenCost(
            inputTokens: 1_234_567,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        XCTAssertEqual(cost.formattedTokens, "1,234,567")
    }

    func testIdProperty() {
        let claudeCost = makeTokenCost(provider: .claudeCode)
        XCTAssertEqual(claudeCost.id, "Claude Code")

        let cursorCost = makeTokenCost(provider: .cursor)
        XCTAssertEqual(cursorCost.id, "Cursor")
    }

    func testCodable() throws {
        let original = makeTokenCost(
            provider: .claudeCode,
            inputTokens: 5000,
            outputTokens: 2500,
            estimatedCostUSD: 0.15
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(TokenCost.self, from: encoded)

        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.inputTokens, original.inputTokens)
        XCTAssertEqual(decoded.outputTokens, original.outputTokens)
        XCTAssertEqual(decoded.estimatedCostUSD, original.estimatedCostUSD, accuracy: 0.01)
    }

    // MARK: - CostSummary Tests

    func testCostSummaryTotalCost() {
        let costs = [
            makeTokenCost(estimatedCostUSD: 1.00),
            makeTokenCost(estimatedCostUSD: 2.50),
            makeTokenCost(estimatedCostUSD: 0.75),
        ]
        let summary = CostSummary(costs: costs, totalCostUSD: 4.25, totalTokens: 10000, periodDays: 30)

        XCTAssertEqual(summary.formattedTotalCost, "$4.25")
    }

    func testCostSummaryTotalCostUsesThousandsSeparator() {
        let summary = CostSummary(costs: [], totalCostUSD: 12_345.60, totalTokens: 10000, periodDays: 30)

        XCTAssertEqual(summary.formattedTotalCost, "$12,345.60")
    }

    func testCostSummaryAverageDailyCost() {
        let summary = CostSummary(costs: [], totalCostUSD: 30.0, totalTokens: 100000, periodDays: 30)
        XCTAssertEqual(summary.averageDailyCost, 1.0, accuracy: 0.01)
        XCTAssertEqual(summary.formattedDailyCost, "$1.00/day")
    }

    func testCostSummaryDailyCostUsesThousandsSeparator() {
        let summary = CostSummary(costs: [], totalCostUSD: 37_036.80, totalTokens: 100000, periodDays: 30)

        XCTAssertEqual(summary.formattedDailyCost, "$1,234.56/day")
    }

    func testCostSummaryAverageDailyCostZeroDays() {
        let summary = CostSummary(costs: [], totalCostUSD: 100.0, totalTokens: 50000, periodDays: 0)
        XCTAssertEqual(summary.averageDailyCost, 0.0, accuracy: 0.01)
        XCTAssertEqual(summary.formattedDailyCost, "$0.00/day")
    }

    func testCostSummaryEmptyCosts() {
        let summary = CostSummary(costs: [], totalCostUSD: 0.0, totalTokens: 0, periodDays: 7)
        XCTAssertEqual(summary.costs.count, 0)
        XCTAssertEqual(summary.formattedTotalCost, "$0.00")
    }

    func testMissingDailyUsageRefreshIsNeededForLegacyCostCache() {
        let now = makeDate(year: 2026, month: 6, day: 26)
        let summary = CostSummary(
            costs: [makeTokenCost()],
            totalCostUSD: 10,
            totalTokens: 1_000,
            periodDays: 30,
            dailyUsage: []
        )

        XCTAssertTrue(summary.needsMissingDailyUsageRefresh(days: 30, lastScanDate: now, now: now, calendar: utcCalendar))
    }

    func testMissingDailyUsageRefreshIsNeededWhenScannedBeforeTodayAndWindowHasGaps() {
        let now = makeDate(year: 2026, month: 6, day: 26)
        let previousScan = makeDate(year: 2026, month: 6, day: 25)
        let summary = CostSummary(
            costs: [makeTokenCost()],
            totalCostUSD: 10,
            totalTokens: 1_000,
            periodDays: 3,
            dailyUsage: [
                makeDailyUsage(date: makeDate(year: 2026, month: 6, day: 24)),
                makeDailyUsage(date: makeDate(year: 2026, month: 6, day: 26)),
            ]
        )

        XCTAssertTrue(
            summary.needsMissingDailyUsageRefresh(days: 3, lastScanDate: previousScan, now: now, calendar: utcCalendar)
        )
    }

    func testMissingDailyUsageRefreshIsSkippedAfterTodayScan() {
        let now = makeDate(year: 2026, month: 6, day: 26)
        let summary = CostSummary(
            costs: [makeTokenCost()],
            totalCostUSD: 10,
            totalTokens: 1_000,
            periodDays: 3,
            dailyUsage: [
                makeDailyUsage(date: makeDate(year: 2026, month: 6, day: 24)),
                makeDailyUsage(date: makeDate(year: 2026, month: 6, day: 26)),
            ]
        )

        XCTAssertFalse(summary.needsMissingDailyUsageRefresh(days: 3, lastScanDate: now, now: now, calendar: utcCalendar))
    }

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTokenCost(
        provider: ServiceType = .claudeCode,
        inputTokens: Int = 1000,
        outputTokens: Int = 500,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        estimatedCostUSD: Double = 0.10,
        sessionCount: Int = 5
    ) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            estimatedCostUSD: estimatedCostUSD,
            sessionCount: sessionCount,
            periodStart: Date().addingTimeInterval(-86400 * 30),
            periodEnd: Date()
        )
    }

    private func makeDailyUsage(
        date: Date,
        provider: ServiceType = .claudeCode,
        inputTokens: Int = 1_000,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        estimatedCostUSD: Double = 1
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            estimatedCostUSD: estimatedCostUSD
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        DateComponents(
            calendar: utcCalendar,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: 12
        ).date!
    }
}
