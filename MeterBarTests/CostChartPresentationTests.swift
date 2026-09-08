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
        XCTAssertEqual(presentation.crossProviderModelPoints.count, 1)
        XCTAssertEqual(presentation.crossProviderModelPoints.first?.model, "shared-model")
        XCTAssertEqual(presentation.crossProviderModelPoints.first?.chartLabel, "shared-model")
        XCTAssertEqual(presentation.crossProviderModelPoints.first?.costUSD ?? 0, 3, accuracy: 0.001)
    }

    func testSevenDayWindowDerivesModelSpendFromAttributedDailyRows() {
        let summary = makeSummary(
            costs: [
                tokenCost(
                    provider: .claudeCode,
                    totalCost: 40,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 40)]
                ),
            ],
            dailyUsage: [
                dailyRow(
                    daysAgo: 2,
                    provider: .claudeCode,
                    cost: 4,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 4)]
                ),
                dailyRow(
                    daysAgo: 5,
                    provider: .codexCli,
                    cost: 3,
                    models: [model(provider: .codexCli, name: "gpt-5.6-sol", cost: 3)]
                ),
                // Outside the 7-day window: must not leak into the model chart.
                dailyRow(
                    daysAgo: 20,
                    provider: .claudeCode,
                    cost: 33,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 33)]
                ),
            ]
        )

        let presentation = CostChartPresentation(
            summary: summary,
            requestedDays: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(presentation.modelWindowDays, 7)
        XCTAssertTrue(presentation.modelWindowMatchesRequested)
        XCTAssertEqual(presentation.modelPoints.count, 2)
        XCTAssertEqual(
            presentation.modelPoints.first { $0.model == "claude-fable-5" }?.costUSD ?? 0,
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(presentation.modelTotalUSD, 7, accuracy: 0.000_001)
        XCTAssertEqual(presentation.selectedPeriodTotalUSD, 7, accuracy: 0.000_001)
        XCTAssertTrue(presentation.modelTotalReconciles)
    }

    func testSevenDayWindowReportsUnattributedRemainderPerDay() {
        let summary = makeSummary(
            dailyUsage: [
                dailyRow(
                    daysAgo: 1,
                    provider: .claudeCode,
                    cost: 5,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 3)]
                ),
            ]
        )

        let presentation = CostChartPresentation(
            summary: summary,
            requestedDays: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            presentation.modelPoints.first { $0.model == "Unattributed" }?.costUSD ?? 0,
            2,
            accuracy: 0.000_001
        )
        XCTAssertTrue(presentation.hasUnattributedModelSpend)
        XCTAssertTrue(presentation.modelTotalReconciles)
    }

    func testSevenDayWindowFallsBackToPeriodModelDetailWhenRowsPredateAttribution() {
        let summary = makeSummary(
            costs: [
                tokenCost(
                    provider: .claudeCode,
                    totalCost: 40,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 40)]
                ),
            ],
            dailyUsage: [
                // v1 cache rows: no model attribution to re-window from.
                dailyRow(daysAgo: 1, provider: .claudeCode, cost: 4),
            ]
        )

        let presentation = CostChartPresentation(
            summary: summary,
            requestedDays: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(presentation.modelWindowDays, 30, "period detail is the honest fallback")
        XCTAssertFalse(presentation.modelWindowMatchesRequested)
        XCTAssertEqual(presentation.modelTotalUSD, 40, accuracy: 0.000_001)
    }

    func testFullWindowKeepsTheAuthoritativePeriodModelDetail() {
        let summary = makeSummary(
            costs: [
                tokenCost(
                    provider: .claudeCode,
                    totalCost: 40,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 40)]
                ),
            ],
            dailyUsage: [
                dailyRow(
                    daysAgo: 1,
                    provider: .claudeCode,
                    cost: 4,
                    models: [model(provider: .claudeCode, name: "claude-fable-5", cost: 4)]
                ),
            ]
        )

        let presentation = CostChartPresentation(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(presentation.modelWindowDays, 30)
        XCTAssertEqual(
            presentation.modelTotalUSD,
            40,
            accuracy: 0.000_001,
            "a 30-day request must keep the scan's own totals, not re-derive them from daily rows"
        )
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

    /// `America/Los_Angeles` transitions at 02:00 local, so its `startOfDay`
    /// is always midnight and this zone cannot reproduce the day-stepping bug
    /// at all — the original version of this test asserted only bucket count
    /// and day span, so it kept passing even while every bucket read as an
    /// empty/zero day. `America/Santiago` on 2026-09-06 transitions *at*
    /// local midnight (00:00–01:00 does not exist that day), so
    /// `calendar.startOfDay(for: now)` returns 01:00 instead of 00:00. A
    /// day-stepping helper that does not re-normalize after every hop
    /// preserves that 01:00 wall clock on every other day, so a bucket key
    /// never equals `startOfDay` of the day it is meant to represent and the
    /// row filed under that day is silently dropped.
    func testCalendarDayMathSurvivesDSTTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let formatter = ISO8601DateFormatter()
        // 10:00 local on the transition day, well after the 01:00 jump.
        let dstNow = formatter.date(from: "2026-09-06T13:00:00Z") ?? now

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let date = santiago.date(from: components) ?? dstNow
            return santiago.startOfDay(for: date)
        }

        // The transition day itself lands on 01:00, not midnight — the
        // premise this test depends on.
        XCTAssertEqual(santiago.component(.hour, from: exactDay(2026, 9, 6)), 1)

        func row(_ date: Date, costUSD: Double) -> DailyTokenUsage {
            DailyTokenUsage(
                date: date,
                provider: .claudeCode,
                inputTokens: 1,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: costUSD
            )
        }

        let summary = makeSummary(
            dailyUsage: [
                row(exactDay(2026, 9, 4), costUSD: 7),
                row(exactDay(2026, 9, 5), costUSD: 5),
                row(exactDay(2026, 9, 6), costUSD: 3),
            ]
        )

        let presentation = CostChartPresentation(
            summary: summary,
            requestedDays: 3,
            now: dstNow,
            calendar: santiago
        )

        XCTAssertEqual(presentation.dailyBuckets.count, 3)
        XCTAssertEqual(
            santiago.dateComponents(
                [.day],
                from: presentation.startDate,
                to: presentation.endDate
            ).day,
            2
        )
        // The regression itself: every day's real spend must land in its own
        // bucket, oldest first, rather than reading as an empty/zero day
        // because its key drifted off the exact `startOfDay` boundary.
        XCTAssertEqual(presentation.dailyBuckets.map(\.costUSD), [7, 5, 3])
        XCTAssertEqual(presentation.dailyTotalUSD, 15, accuracy: 0.000_001)
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
        let start = CostWindow.start(days: 30, now: now, calendar: calendar)

        XCTAssertEqual(start, dailyDate(daysAgo: 29))
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06,
    /// so `startOfDay(now)` on that day is 01:00, not 00:00. A single
    /// `byAdding(.day, -29)` hop from that instant preserves 01:00 on the
    /// resulting day, which would never equal `startOfDay` for that day's
    /// rows — turning a "30 days" window into an off-by-one that silently
    /// drops the oldest day. The UTC-pinned test above cannot exercise this.
    func testCostWindowStartLandsOnMidnightAcrossTheSantiagoTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let dstNow = ISO8601DateFormatter().date(from: "2026-09-06T13:00:00Z") ?? now

        XCTAssertEqual(santiago.component(.hour, from: santiago.startOfDay(for: dstNow)), 1)

        let start = CostWindow.start(days: 30, now: dstNow, calendar: santiago)

        XCTAssertEqual(santiago.component(.hour, from: start), 0)
        XCTAssertEqual(start, santiago.startOfDay(for: start))
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
        cost: Double,
        models: [TokenUsageBreakdown]? = nil
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: dailyDate(daysAgo: daysAgo),
            provider: provider,
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: cost,
            modelBreakdowns: models
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
