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

    /// Regression for #537: a linear `"opus-4".contains` match tried before
    /// `"opus"` priced every `claude-opus-4*` model — including the
    /// still-$15/$75 Opus 4 and 4.1 — at the reduced 4.8 rate. Only the
    /// explicitly reduced 4-6/4-7/4-8 snapshots should get $5/$25; a bare
    /// "opus-4" or "opus-4-1" must fall through to the legacy $15/$75 rate.
    func testAnthropicOpus4WithoutAReducedSnapshotUsesLegacyRate() {
        for model in ["claude-opus-4", "claude-opus-4-1", "claude-opus-4-20260214"] {
            let cost = ApiUsagePricing.cost(
                provider: .anthropic, model: model, inputTokens: 1_000_000, outputTokens: 0
            )
            XCTAssertEqual(cost, 15.0, accuracy: 0.0001, "\(model) should price at the legacy opus rate")
        }
    }

    /// Worked example from #537: an admin key dominated by cache reads (the
    /// common shape for a Claude Code workload) must price the cache-read
    /// tokens at the cache-read rate, not the full uncached-input rate.
    /// 100M cache-read + 1M uncached input + 1M output on claude-sonnet-4-5
    /// is 100 * $0.30 + 1 * $3 + 1 * $15 = $48.00, not (101 * $3) + (1 * $15)
    /// = $318.00.
    func testCacheReadTokensPriceAtTheCacheReadRateNotTheInputRate() {
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-sonnet-4-5",
            tokens: ApiUsagePricing.TokenBreakdown(
                uncachedInput: 1_000_000,
                cacheRead: 100_000_000,
                output: 1_000_000
            )
        )
        XCTAssertEqual(cost, 48.0, accuracy: 0.0001)
    }

    /// Anthropic's 1h/5m cache-creation tiers must each price at their own
    /// rate too, not fold into the input rate.
    func testCacheCreationTiersPriceIndependently() {
        let cost = ApiUsagePricing.cost(
            provider: .anthropic,
            model: "claude-sonnet-4-5",
            tokens: ApiUsagePricing.TokenBreakdown(
                cacheCreationFiveMinute: 1_000_000,
                cacheCreationOneHour: 1_000_000
            )
        )
        // Sonnet 4.5: 5m cache-creation $3.75, 1h cache-creation $6.00.
        XCTAssertEqual(cost, 3.75 + 6.00, accuracy: 0.0001)
    }

    func testUnknownModelPricingIsMarkedUnverified() {
        XCTAssertFalse(ApiUsagePricing.isPricingUnverified(provider: .anthropic, model: "claude-sonnet-4-5"))
        XCTAssertTrue(ApiUsagePricing.isPricingUnverified(provider: .anthropic, model: "totally-unknown"))
        XCTAssertTrue(ApiUsagePricing.isPricingUnverified(provider: .anthropic, model: nil))

        XCTAssertFalse(ApiUsagePricing.isPricingUnverified(provider: .openai, model: "gpt-4o"))
        XCTAssertTrue(ApiUsagePricing.isPricingUnverified(provider: .openai, model: "totally-unknown"))
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

    /// Regression for #554: gpt-4.1's cached input is 75% off, not the 50%
    /// uniform discount the old local table guessed for every OpenAI model.
    func testOpenAIGpt41CacheReadPricesAtItsOwnDiscountNotTheGpt4oRate() {
        let cost = ApiUsagePricing.cost(
            provider: .openai,
            model: "gpt-4.1",
            tokens: ApiUsagePricing.TokenBreakdown(cacheRead: 1_000_000)
        )
        // $0.50 per million at the verified 75%-off rate, not $1.00 (the old
        // uniform-50%-off guess) or $2.00 (the uncached input rate).
        XCTAssertEqual(cost, 0.50, accuracy: 0.0001)
    }

    /// Regression for #554: substring matching in list order could mis-price
    /// a model — the same defect class that priced Anthropic's Opus 4 at a
    /// third of its rate before #537. "gpt-4" must never shadow "gpt-4o",
    /// "gpt-4.1", or "gpt-4-turbo".
    func testOpenAIExactMatchNeverLetsAShorterSlugShadowAMoreSpecificOne() {
        XCTAssertEqual(
            ApiUsagePricing.cost(provider: .openai, model: "gpt-4", inputTokens: 1_000_000, outputTokens: 0),
            30.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ApiUsagePricing.cost(provider: .openai, model: "gpt-4o", inputTokens: 1_000_000, outputTokens: 0),
            2.50, accuracy: 0.0001
        )
        XCTAssertEqual(
            ApiUsagePricing.cost(provider: .openai, model: "gpt-4-turbo", inputTokens: 1_000_000, outputTokens: 0),
            10.0, accuracy: 0.0001
        )
        XCTAssertEqual(
            ApiUsagePricing.cost(provider: .openai, model: "gpt-4.1", inputTokens: 1_000_000, outputTokens: 0),
            2.0, accuracy: 0.0001
        )
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
        let calendar = utcCalendar
        let early = date(year: 2026, month: 7, day: 2, hour: 15)
        let late = date(year: 2026, month: 7, day: 5, hour: 9)

        // Reversed picker values normalize to the first selected day through
        // the start of the day after the final selected day.
        let range = ApiUsageWindow.custom(start: late, end: early).dateRange(calendar: calendar)
        XCTAssertEqual(range.start, date(year: 2026, month: 7, day: 2))
        XCTAssertEqual(range.end, date(year: 2026, month: 7, day: 6))
    }

    func testSameDayCustomWindowIncludesTheWholeSelectedDay() {
        let selected = date(year: 2026, month: 7, day: 9, hour: 18)

        let range = ApiUsageWindow.custom(start: selected, end: selected)
            .dateRange(calendar: utcCalendar)

        XCTAssertEqual(range.start, date(year: 2026, month: 7, day: 9))
        XCTAssertEqual(range.end, date(year: 2026, month: 7, day: 10))
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 86_400)
    }

    // MARK: - DTO decoding

    func testAnthropicUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            {
              "starting_at": "2026-07-01T00:00:00Z",
              "ending_at": "2026-07-02T00:00:00Z",
              "results": [
                {
                  "uncached_input_tokens": 1000,
                  "cache_read_input_tokens": 400,
                  "cache_creation": {
                    "ephemeral_1h_input_tokens": 300,
                    "ephemeral_5m_input_tokens": 200
                  },
                  "output_tokens": 500,
                  "server_tool_use": {
                    "web_search_requests": 2
                  },
                  "model": "claude-sonnet-4-5",
                  "service_tier": "standard"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let response = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.count, 1)
        let result = try XCTUnwrap(response.data.first?.results.first)
        XCTAssertEqual(result.model, "claude-sonnet-4-5")
        XCTAssertEqual(result.uncachedInputTokens, 1000)
        XCTAssertEqual(result.cacheReadInputTokens, 400)
        XCTAssertEqual(result.cacheCreation?.ephemeral1HourInputTokens, 300)
        XCTAssertEqual(result.cacheCreation?.ephemeral5MinuteInputTokens, 200)
        XCTAssertEqual(result.outputTokens, 500)
        XCTAssertEqual(result.totalInputTokens, 1900)
        XCTAssertEqual(response.hasMore, false)

        let usage = ApiUsageService.aggregateAnthropic(
            buckets: response.data,
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(usage.inputTokens, 1900)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.models.first?.model, "claude-sonnet-4-5")
        XCTAssertFalse(usage.hasIncompleteInputData)
        XCTAssertFalse(usage.hasUnverifiedPricing)
        XCTAssertFalse(usage.isTruncated)

        // Sonnet 4.5: 1000 uncached-input * $3 + 400 cache-read * $0.30 +
        // 200 5m cache-creation * $3.75 + 300 1h cache-creation * $6.00 +
        // 500 output * $15, all per-million. This is the flattening bug's
        // regression test: pre-fix, all 1900 input tokens were billed at the
        // uncached $3 rate for $0.0195 instead of $0.01317.
        XCTAssertEqual(usage.estimatedCostUSD, 0.01317, accuracy: 0.000_001)
    }

    /// #537's field-rename scenario: every input-token key is absent (not
    /// present-and-zero) while `output_tokens` survives. The row must not be
    /// reported as a confident zero-input cost — it has to be flagged.
    func testAnthropicUsageWithNoInputKeysIsFlaggedNotSilentlyZero() throws {
        let json = """
        {
          "data": [
            { "results": [
              { "output_tokens": 500, "model": "claude-sonnet-4-5" }
            ] }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let response = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        let result = try XCTUnwrap(response.data.first?.results.first)
        XCTAssertTrue(result.hasNoInputTokenData)

        let usage = ApiUsageService.aggregateAnthropic(
            buckets: response.data,
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertTrue(usage.hasIncompleteInputData)
        XCTAssertTrue(usage.models.first?.hasIncompleteInputData ?? false)
    }

    func testOpenAIUsageResponseDecodes() throws {
        let json = """
        {
          "data": [
            { "results": [
              { "model": "gpt-4o", "input_tokens": 800, "input_cached_tokens": 300, "output_tokens": 400 }
            ] }
          ],
          "has_more": true,
          "next_page": "abc"
        }
        """
        let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.first?.results.first?.model, "gpt-4o")
        XCTAssertEqual(response.data.first?.results.first?.inputTokens, 800)
        XCTAssertEqual(response.data.first?.results.first?.inputCachedTokens, 300)
        XCTAssertEqual(response.data.first?.results.first?.outputTokens, 400)
        XCTAssertEqual(response.nextPage, "abc")

        // #554: OpenAI's `input_tokens` includes the cached portion, so the
        // aggregation must bill the cached 300 tokens at gpt-4o's cache-read
        // rate ($1.25) and only the remaining 500 uncached tokens at the full
        // input rate ($2.50), not all 800 at the uncached rate.
        let usage = ApiUsageService.aggregateOpenAI(
            buckets: response.data,
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2)
        )
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 400)
        XCTAssertFalse(usage.hasUnverifiedPricing)
        let expectedCost = 500.0 / 1_000_000 * 2.50 + 300.0 / 1_000_000 * 1.25 + 400.0 / 1_000_000 * 10.0
        XCTAssertEqual(usage.estimatedCostUSD, expectedCost, accuracy: 0.000_001)
    }

    /// Regression for #554: an OpenAI model the shared table does not know
    /// must be flagged unverified — never a confidently wrong dollar figure
    /// from a silent default, the same standard #537 holds Anthropic to.
    func testUnmatchedOpenAIModelAggregatesAsUnverified() throws {
        let json = """
        {
          "data": [
            { "results": [
              { "model": "gpt-9-unreleased", "input_tokens": 1000, "output_tokens": 200 }
            ] }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let response = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        let usage = ApiUsageService.aggregateOpenAI(
            buckets: response.data,
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2)
        )
        XCTAssertTrue(usage.hasUnverifiedPricing)
        XCTAssertTrue(usage.models.first?.isPricingUnverified ?? false)
    }

    // MARK: - Pagination

    /// Regression for #537: a window whose usage paginates past the safety
    /// cap must surface that its total is partial, not return the partial
    /// sum silently as the window total.
    func testPaginationBeyondTheCapIsSurfacedAsTruncated() async throws {
        var pagesRequested = 0
        let result = try await ApiUsageService.paginate(maxPages: 3) { pageToken -> (data: [Int], hasMore: Bool, nextPage: String?) in
            pagesRequested += 1
            let page = Int(pageToken ?? "0") ?? 0
            // Always reports more data available — a well-behaved provider
            // that simply has more pages than the cap allows.
            return ([page], true, String(page + 1))
        }
        XCTAssertEqual(pagesRequested, 3)
        XCTAssertEqual(result.pages, [0, 1, 2])
        XCTAssertTrue(result.isTruncated)
    }

    func testPaginationThatEndsBeforeTheCapIsNotTruncated() async throws {
        let result = try await ApiUsageService.paginate(maxPages: 50) { pageToken -> (data: [Int], hasMore: Bool, nextPage: String?) in
            let page = Int(pageToken ?? "0") ?? 0
            if page >= 2 {
                return ([page], false, nil)
            }
            return ([page], true, String(page + 1))
        }
        XCTAssertEqual(result.pages, [0, 1, 2])
        XCTAssertFalse(result.isTruncated)
    }

    /// A truncated Anthropic fetch threads through to the aggregated
    /// `ApiUsage` the UI reads, not just the internal pagination helper.
    func testTruncatedAnthropicAggregationMarksApiUsage() {
        let bucket = AnthropicUsageBucket(results: [
            AnthropicUsageResult(
                uncachedInputTokens: 100,
                cacheReadInputTokens: 0,
                cacheCreation: nil,
                outputTokens: 50,
                model: "claude-sonnet-4-5"
            )
        ])
        let usage = ApiUsageService.aggregateAnthropic(
            buckets: [bucket],
            start: date(year: 2026, month: 7, day: 1),
            end: date(year: 2026, month: 7, day: 2),
            isTruncated: true
        )
        XCTAssertTrue(usage.isTruncated)
    }

    // MARK: - Safe errors

    func testHTTPValidationDropsProviderResponseBody() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.test/usage"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)
        )
        let body = Data(#"{"email":"person@example.test","token":"sk-secret"}"#.utf8)

        XCTAssertThrowsError(try ServiceSupport.validate(response, data: body)) { error in
            XCTAssertEqual((error as? ServiceError)?.errorDescription, "HTTP 500")
            XCTAssertFalse(error.localizedDescription.contains("person@example.test"))
            XCTAssertFalse(error.localizedDescription.contains("sk-secret"))
        }
    }

    func testSafeErrorMessageDropsUnknownLocalizedDetails() {
        struct SecretError: LocalizedError {
            var errorDescription: String? { "provider body contained sk-secret" }
        }

        XCTAssertEqual(ServiceSupport.safeErrorMessage(for: SecretError()), "Request failed")
        XCTAssertEqual(
            ServiceSupport.safeErrorMessage(for: ServiceError.apiError("HTTP 429: account@example.test")),
            "HTTP 429"
        )

        let urlError = URLError(
            .badServerResponse,
            userInfo: [NSLocalizedDescriptionKey: "request failed for https://example.test?token=sk-secret"]
        )
        XCTAssertEqual(ServiceSupport.safeErrorMessage(for: urlError), "Network request failed")
    }

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }
}
