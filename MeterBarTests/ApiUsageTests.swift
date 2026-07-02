import XCTest
@testable import MeterBar

final class ApiUsageTests: XCTestCase {
    // MARK: - Pricing

    func testAnthropicPricingMatchesModel() {
        // 1M input + 1M output of Sonnet = $3 + $15.
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-sonnet-4-5",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        XCTAssertEqual(cost, 18.0, accuracy: 0.0001)
    }

    func testAnthropicOpus4UsesReducedRate() {
        // opus-4-8 = $5 in / $25 out, not the legacy opus $15/$75.
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-opus-4-8",
            inputTokens: 1_000_000,
            outputTokens: 0
        )
        XCTAssertEqual(cost, 5.0, accuracy: 0.0001)
    }

    func testOpenAIPricingMatchesModel() {
        // gpt-4o = $2.50 in / $10 out.
        let cost = ApiUsagePricing.cost(
            provider: .openai,
            model: "gpt-4o",
            inputTokens: 2_000_000,
            outputTokens: 500_000
        )
        XCTAssertEqual(cost, 2 * 2.50 + 0.5 * 10.0, accuracy: 0.0001)
    }

    func testUnknownModelFallsBackToProviderDefault() {
        let anthropic = ApiUsagePricing.cost(
            provider: .anthropic, model: "totally-unknown", inputTokens: 1_000_000, outputTokens: 0
        )
        let openai = ApiUsagePricing.cost(
            provider: .openai, model: nil, inputTokens: 1_000_000, outputTokens: 0
        )
        XCTAssertEqual(anthropic, 3.0, accuracy: 0.0001) // anthropic default input
        XCTAssertEqual(openai, 2.50, accuracy: 0.0001)   // openai default input
    }

    // MARK: - Window

    func testWindowRanges() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let sevenDays = ApiUsageWindow.last7Days.dateRange(now: now)
        XCTAssertEqual(now.timeIntervalSince(sevenDays.start), 7 * 86_400, accuracy: 1)
        XCTAssertEqual(sevenDays.end, now)

        let thirty = ApiUsageWindow.last30Days.dateRange(now: now)
        XCTAssertEqual(now.timeIntervalSince(thirty.start), 30 * 86_400, accuracy: 1)
    }

    func testCustomWindowNormalizesOrder() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        // Even if passed reversed, start <= end.
        let range = ApiUsageWindow.custom(start: late, end: early).dateRange()
        XCTAssertEqual(range.start, early)
        XCTAssertEqual(range.end, late)
    }

    // MARK: - DTO decoding

    func testAnthropicUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            { "model": "claude-sonnet-4-5", "input_tokens": 1000, "output_tokens": 500,
              "cache_creation_input_tokens": 200 }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let response = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(response.data[0].inputTokens, 1000)
        XCTAssertEqual(response.data[0].cacheCreationInputTokens, 200)
        XCTAssertEqual(response.hasMore, false)
    }

    func testOpenAIUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            { "results": [
              { "model": "gpt-4o", "input_tokens": 800, "output_tokens": 400 }
            ] }
          ],
          "has_more": true,
          "next_page": "abc"
        }
        """
        let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.first?.results.first?.model, "gpt-4o")
        XCTAssertEqual(response.data.first?.results.first?.outputTokens, 400)
        XCTAssertEqual(response.nextPage, "abc")
    }
}
