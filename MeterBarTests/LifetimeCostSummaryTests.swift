import MeterBarShared
import XCTest
@testable import MeterBar

final class LifetimeCostSummaryTests: XCTestCase {
    private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let middleDate = Date(timeIntervalSince1970: 1_710_000_000)
    private let lastDate = Date(timeIntervalSince1970: 1_720_000_000)

    func testAggregatesFixtureAcrossProvidersAndDates() {
        let summary = LifetimeCostSummary(costs: [
            cost(provider: .claudeCode, amount: 1.25, start: firstDate, end: middleDate),
            cost(provider: .claudeCode, amount: 2.75, start: middleDate, end: lastDate),
            cost(provider: .codexCli, amount: 3.50, start: middleDate, end: lastDate)
        ])

        XCTAssertEqual(summary.providers.map(\.provider), [.claudeCode, .codexCli])
        XCTAssertEqual(summary.providers[0].estimatedCostUSD, 4.00, accuracy: 0.0001)
        XCTAssertEqual(summary.providers[1].estimatedCostUSD, 3.50, accuracy: 0.0001)
        XCTAssertEqual(summary.totalCostUSD, 7.50, accuracy: 0.0001)
        XCTAssertEqual(summary.firstTrackedDate, firstDate)
        XCTAssertEqual(summary.lastTrackedDate, lastDate)
        XCTAssertEqual(
            summary.providers.reduce(0) { $0 + $1.estimatedCostUSD },
            summary.totalCostUSD,
            accuracy: 0.0001
        )
    }

    func testEmptyAndZeroCostFixturesHaveNoBillableHistory() {
        let empty = LifetimeCostSummary(costs: [])
        let zero = LifetimeCostSummary(costs: [
            cost(provider: .claudeCode, amount: 0, start: firstDate, end: lastDate)
        ])

        for summary in [empty, zero] {
            XCTAssertFalse(summary.hasBillableHistory)
            XCTAssertTrue(summary.providers.isEmpty)
            XCTAssertEqual(summary.totalCostUSD, 0, accuracy: 0.0001)
            XCTAssertNil(summary.firstTrackedDate)
            XCTAssertNil(summary.lastTrackedDate)
        }
    }

    func testRebuildingTheSameScanDoesNotAccumulateHistory() {
        let fixture = [
            cost(provider: .claudeCode, amount: 2.25, start: firstDate, end: lastDate),
            cost(provider: .codexCli, amount: 1.75, start: middleDate, end: lastDate)
        ]

        let firstScan = LifetimeCostSummary(costs: fixture)
        let repeatedScan = LifetimeCostSummary(costs: fixture)

        XCTAssertEqual(repeatedScan, firstScan)
        XCTAssertEqual(repeatedScan.totalCostUSD, 4.00, accuracy: 0.0001)
    }

    func testFilteringReconcilesProviderSubtotalAndTrackedRange() {
        let summary = LifetimeCostSummary(costs: [
            cost(provider: .claudeCode, amount: 2.00, start: firstDate, end: middleDate),
            cost(provider: .codexCli, amount: 3.00, start: middleDate, end: lastDate)
        ])

        let filtered = summary.filtered(to: [.codexCli])

        XCTAssertEqual(filtered.providers.map(\.provider), [.codexCli])
        XCTAssertEqual(filtered.totalCostUSD, 3.00, accuracy: 0.0001)
        XCTAssertEqual(filtered.firstTrackedDate, middleDate)
        XCTAssertEqual(filtered.lastTrackedDate, lastDate)
    }

    func testLegacyCachedSummaryDecodesWithoutLifetimeSnapshot() throws {
        let data = Data(
            """
            {
              "costs": [],
              "totalCostUSD": 0,
              "totalTokens": 0,
              "periodDays": 30,
              "dailyUsage": []
            }
            """.utf8
        )

        let summary = try JSONDecoder().decode(CostSummary.self, from: data)

        XCTAssertNil(summary.lifetime)
    }

    func testCachedSummaryRoundTripsLifetimeSnapshot() throws {
        let lifetime = LifetimeCostSummary(costs: [
            cost(provider: .claudeCode, amount: 4.25, start: firstDate, end: lastDate)
        ])
        let original = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            lifetime: lifetime
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CostSummary.self, from: data)

        XCTAssertEqual(decoded.lifetime, lifetime)
    }

    private func cost(
        provider: ServiceType,
        amount: Double,
        start: Date,
        end: Date
    ) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: 1_000,
            outputTokens: 500,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: amount,
            sessionCount: 1,
            periodStart: start,
            periodEnd: end
        )
    }
}
