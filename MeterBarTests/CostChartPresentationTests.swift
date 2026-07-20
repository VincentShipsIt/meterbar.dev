import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class CostChartPresentationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testDailyBucketsAreOldestFirstAndUseInclusiveCalendarBoundaries() {
        let summary = makeSummary(
            dailyUsage: [
                dailyRow(daysAgo: 0, provider: .claudeCode, cost: 1),
                dailyRow(daysAgo: 29, provider: .codexCli, cost: 2),
                dailyRow(daysAgo: 30, provider: .claudeCode, cost: 99),
            ]
        )

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(presentation.dailyBuckets.count, 30)
        XCTAssertEqual(presentation.dailyBuckets.map(\.date), presentation.dailyBuckets.map(\.date).sorted())
        XCTAssertEqual(presentation.dailyTotalUSD, 3, accuracy: 0.000_001)
        XCTAssertEqual(presentation.dailyProviderPoints.count, 2)
        XCTAssertFalse(presentation.dailyProviderPoints.contains { $0.costUSD == 99 })
    }

    func testGroupsRowsIntoCalendarDaysAcrossProviders() {
        let today = calendar.startOfDay(for: now)
        let midday = calendar.date(byAdding: .hour, value: 12, to: today) ?? today
        let summary = makeSummary(
            dailyUsage: [
                DailyTokenUsage(
                    date: today,
                    provider: .claudeCode,
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1.25
                ),
                DailyTokenUsage(
                    date: midday,
                    provider: .claudeCode,
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0.75
                ),
                DailyTokenUsage(
                    date: today,
                    provider: .codexCli,
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0.50
                ),
            ]
        )

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(presentation.dailyBuckets.last?.costUSD, 2.50)
        XCTAssertEqual(
            presentation.dailyProviderPoints.map(\.costUSD).sorted(),
            [0.50, 2.00]
        )
    }

    func testPartialCoverageUsesGapsThenCoveredZeroDays() {
        let summary = makeSummary(
            dailyUsage: [
                dailyRow(daysAgo: 2, provider: .claudeCode, cost: 1),
                dailyRow(daysAgo: 0, provider: .claudeCode, cost: 2),
            ],
            periodDays: 30
        )

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(presentation.coveredDays, 3)
        XCTAssertEqual(presentation.dailyBuckets.filter { $0.costUSD == nil }.count, 27)
        XCTAssertEqual(presentation.zeroSpendDays.count, 1)
        XCTAssertEqual(presentation.zeroSpendDays.first?.date, dailyDate(daysAgo: 1))
    }

    func testModelSpendGroupsDuplicatesAndReconcilesToSelectedPeriod() {
        let summary = makeSummary(costs: [
            tokenCost(
                provider: .claudeCode,
                totalCost: 4,
                models: [
                    model(provider: .claudeCode, name: "claude-fable-5", cost: 1.5),
                    model(provider: .claudeCode, name: "claude-fable-5", cost: 0.5),
                    model(provider: .claudeCode, name: "claude-opus-4-8", cost: 2),
                ]
            ),
            tokenCost(
                provider: .codexCli,
                totalCost: 3,
                models: [
                    model(provider: .codexCli, name: "gpt-5.6-sol", cost: 3),
                ]
            ),
        ])

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(presentation.modelPoints.count, 3)
        XCTAssertEqual(
            presentation.modelPoints.first { $0.model == "claude-fable-5" }?.costUSD,
            2
        )
        XCTAssertEqual(presentation.modelTotalUSD, 7, accuracy: 0.000_001)
        XCTAssertEqual(presentation.selectedPeriodTotalUSD, 7, accuracy: 0.000_001)
        XCTAssertTrue(presentation.modelTotalReconciles)
    }

    func testMissingModelMetadataUsesHonestUnattributedRemainder() {
        let summary = makeSummary(costs: [
            tokenCost(
                provider: .claudeCode,
                totalCost: 5,
                models: [
                    model(provider: .claudeCode, name: "claude-fable-5", cost: 3),
                ]
            ),
        ])

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(
            presentation.modelPoints.first { $0.model == "Unattributed" }?.costUSD,
            2
        )
        XCTAssertTrue(presentation.hasUnattributedModelSpend)
        XCTAssertTrue(presentation.modelTotalReconciles)
    }

    func testDuplicateModelNamesAcrossProvidersGetUniqueChartLabels() {
        let summary = makeSummary(costs: [
            tokenCost(
                provider: .claudeCode,
                totalCost: 1,
                models: [model(provider: .claudeCode, name: "shared-model", cost: 1)]
            ),
            tokenCost(
                provider: .codexCli,
                totalCost: 2,
                models: [model(provider: .codexCli, name: "shared-model", cost: 2)]
            ),
        ])

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(Set(presentation.modelPoints.map(\.chartLabel)).count, 2)
        XCTAssertTrue(presentation.modelPoints.allSatisfy { $0.chartLabel.contains($0.provider.displayName) })
    }

    func testNegativeCostsDoNotProduceChartMarks() {
        let summary = makeSummary(
            costs: [
                tokenCost(
                    provider: .claudeCode,
                    totalCost: -1,
                    models: [model(provider: .claudeCode, name: "invalid", cost: -2)]
                ),
            ],
            dailyUsage: [dailyRow(daysAgo: 0, provider: .claudeCode, cost: -3)]
        )

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertFalse(presentation.hasSpend)
        XCTAssertTrue(presentation.dailyProviderPoints.isEmpty)
        XCTAssertTrue(presentation.modelPoints.isEmpty)
    }

    func testNormalizesNonPositiveRequestedDaysAndReportsWindowMismatch() {
        let presentation = CostChartPresentation(
            summary: makeSummary(periodDays: 30),
            requestedDays: 0,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(presentation.requestedDays, 1)
        XCTAssertEqual(presentation.dailyBuckets.count, 1)
        XCTAssertFalse(presentation.modelWindowMatchesRequested)
    }

    func testCalendarDayMathSurvivesDSTTransition() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let formatter = ISO8601DateFormatter()
        let dstNow = formatter.date(from: "2026-03-09T12:00:00Z") ?? now
        let presentation = CostChartPresentation(
            summary: makeSummary(),
            requestedDays: 3,
            now: dstNow,
            calendar: losAngeles
        )

        XCTAssertEqual(presentation.dailyBuckets.count, 3)
        XCTAssertEqual(
            losAngeles.dateComponents(
                [.day],
                from: presentation.startDate,
                to: presentation.endDate
            ).day,
            2
        )
    }

    func testEmptySummaryDoesNotFabricateChartData() {
        let presentation = CostChartPresentation(
            summary: makeSummary(),
            now: now,
            calendar: calendar
        )

        XCTAssertFalse(presentation.hasSpend)
        XCTAssertFalse(presentation.hasDailyCoverage)
        XCTAssertTrue(presentation.dailyProviderPoints.isEmpty)
        XCTAssertTrue(presentation.modelPoints.isEmpty)
        XCTAssertTrue(presentation.zeroSpendDays.isEmpty)
    }

    func testCostWindowStartUsesTodayPlusPreviousTwentyNineDays() {
        let start = CostTracker.costWindowStart(days: 30, now: now, calendar: calendar)

        XCTAssertEqual(start, dailyDate(daysAgo: 29))
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
    }

    private func makeSummary(
        costs: [TokenCost] = [],
        dailyUsage: [DailyTokenUsage] = [],
        periodDays: Int = 30
    ) -> CostSummary {
        CostSummary(
            costs: costs,
            totalCostUSD: costs.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: periodDays,
            dailyUsage: dailyUsage
        )
    }

    private func dailyDate(daysAgo: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    private func dailyRow(
        daysAgo: Int,
        provider: ServiceType,
        cost: Double
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: dailyDate(daysAgo: daysAgo),
            provider: provider,
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: cost
        )
    }

    private func tokenCost(
        provider: ServiceType,
        totalCost: Double,
        models: [TokenUsageBreakdown]
    ) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: 1,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: totalCost,
            sessionCount: 1,
            periodStart: dailyDate(daysAgo: 29),
            periodEnd: dailyDate(daysAgo: 0),
            modelBreakdowns: models
        )
    }

    private func model(
        provider: ServiceType,
        name: String,
        cost: Double
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: 1,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: cost,
            sessionCount: 1
        )
    }
}
