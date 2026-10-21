import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class NumericSafetyTests: XCTestCase {
    func testTokenCountSaturatesAndKeepsIntegerWireFormat() throws {
        XCTAssertEqual((TokenCount(.max) + TokenCount(1)).value, .max)
        XCTAssertEqual(TokenCount(-4).value, 0)
        XCTAssertEqual(try JSONEncoder().encode(TokenCount(42)), Data("42".utf8))
        XCTAssertEqual(try JSONDecoder().decode(TokenCount.self, from: Data("42".utf8)).value, 42)
        XCTAssertThrowsError(try JSONDecoder().decode(TokenCount.self, from: Data("-1".utf8)))
    }

    func testCostFoldStaysFiniteAndEncodableAfterInvalidAndOverflowingAmounts() throws {
        var total = 12.5
        for amount in [Double.nan, .infinity, -.infinity, -1] {
            SafeAccumulate.accumulate(&total, amount)
            XCTAssertEqual(total, 12.5)
        }
        SafeAccumulate.accumulate(&total, .greatestFiniteMagnitude)
        SafeAccumulate.accumulate(&total, .greatestFiniteMagnitude)
        XCTAssertEqual(total, .greatestFiniteMagnitude)
        XCTAssertNoThrow(try JSONEncoder().encode(total))
    }

    func testScannerAccumulatorPreservesValidCostAfterNonFiniteEvent() throws {
        var accumulator = TokenAccumulator()
        accumulator.add(input: 10, output: 5, cacheCreation: 0, cacheRead: 0, estimatedCostUSD: 2)
        accumulator.add(input: 10, output: 5, cacheCreation: 0, cacheRead: 0, estimatedCostUSD: .nan)
        XCTAssertEqual(accumulator.estimatedCostUSD, 2)
        XCTAssertEqual(accumulator.input, 20)
        XCTAssertNoThrow(try JSONEncoder().encode(accumulator))
    }

    func testAPIUsageSaturatesAcrossRowsModelsAndTotal() throws {
        let json = """
        {"data":[{"results":[
          {"model":"gpt-4o","input_tokens":\(Int.max),"output_tokens":\(Int.max)},
          {"model":"gpt-4o","input_tokens":100,"output_tokens":100},
          {"model":"gpt-4.1","input_tokens":100,"output_tokens":100}
        ]}],"has_more":false}
        """
        let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ApiUsageService.aggregateOpenAI(buckets: response.data, start: now, end: now)
        XCTAssertEqual(usage.inputTokens, .max)
        XCTAssertEqual(usage.outputTokens, .max)
        XCTAssertEqual(usage.totalTokens, .max)
        XCTAssertTrue(usage.estimatedCostUSD.isFinite)
        XCTAssertEqual(usage.models.count, 2)
    }

    func testAnthropicInputComponentsSaturateBeforePricing() {
        let row = AnthropicUsageResult(
            uncachedInputTokens: .max, cacheReadInputTokens: 1,
            cacheCreation: nil, outputTokens: 1, model: "claude-sonnet-4-5"
        )
        XCTAssertEqual(row.totalInputTokens, .max)
    }
}
