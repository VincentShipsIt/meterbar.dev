import XCTest
import MeterBarShared
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
    }

    func testFormattedTokens() {
        let cost = makeTokenCost(
            inputTokens: 1_234_567,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
        // Should be formatted with decimal separators
        XCTAssertTrue(cost.formattedTokens.contains("1"))
        XCTAssertTrue(cost.formattedTokens.contains("234"))
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

    func testCostSummaryAverageDailyCost() {
        let summary = CostSummary(costs: [], totalCostUSD: 30.0, totalTokens: 100000, periodDays: 30)
        XCTAssertEqual(summary.averageDailyCost, 1.0, accuracy: 0.01)
        XCTAssertEqual(summary.formattedDailyCost, "$1.00/day")
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

    // MARK: - Helpers

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
}
