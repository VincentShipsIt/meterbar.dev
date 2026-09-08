import Foundation

/// Fetches organization API usage (per-model token counts) from the Anthropic
/// and OpenAI admin usage endpoints, aggregates it over a window, and prices it
/// into an `ApiUsage`. Unlike the subscription providers there is no quota — the
/// card shows tokens and an approximate cost, not a percentage or billing total.
enum ApiUsageService {
    /// Safety cap on pagination so a misbehaving API can never loop forever.
    private static let maxUsagePages = 50

    static func fetch(
        provider: ApiProvider,
        adminKey: String,
        window: ApiUsageWindow,
        now: Date = Date()
    ) async throws -> ApiUsage {
        let range = window.dateRange(now: now)
        switch provider {
        case .anthropic:
            return try await fetchAnthropic(adminKey: adminKey, start: range.start, end: range.end)
        case .openai:
            return try await fetchOpenAI(adminKey: adminKey, start: range.start, end: range.end)
        }
    }

    // MARK: - Pagination

    /// Runs a page-cursor fetch loop up to `maxPages`, the safety cap that
    /// stops a misbehaving API from looping forever. Returns every page's data
    /// concatenated, plus whether the provider still reported more data
    /// (`has_more: true`) when the cap was hit — a truncated window total must
    /// be surfaced to the caller, never silently returned as the real total
    /// (#537).
    static func paginate<Page>(
        maxPages: Int = maxUsagePages,
        fetchPage: (_ pageToken: String?) async throws -> (data: [Page], hasMore: Bool, nextPage: String?)
    ) async throws -> (pages: [Page], isTruncated: Bool) {
        var pages: [Page] = []
        var pageToken: String?
        var pagesFetched = 0

        repeat {
            let page = try await fetchPage(pageToken)
            pages.append(contentsOf: page.data)
            pageToken = page.hasMore ? page.nextPage : nil
            pagesFetched += 1
        } while pageToken != nil && pagesFetched < maxPages

        // A non-nil token here means the loop exited because it hit the page
        // cap, not because the provider ran out of data.
        return (pages, pageToken != nil)
    }

    // MARK: - Anthropic

    private static func fetchAnthropic(adminKey: String, start: Date, end: Date) async throws -> ApiUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let baseQueryItems = [
            URLQueryItem(name: "starting_at", value: formatter.string(from: start)),
            URLQueryItem(name: "ending_at", value: formatter.string(from: end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by[]", value: "model")
        ]

        let decoder = JSONDecoder()

        let (buckets, isTruncated) = try await paginate { pageToken in
            guard var components = URLComponents(
                string: "https://api.anthropic.com/v1/organizations/usage_report/messages"
            ) else {
                throw ServiceError.invalidURL
            }
            var queryItems = baseQueryItems
            if let pageToken {
                queryItems.append(URLQueryItem(name: "page", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw ServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let response: AnthropicUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            return (response.data, response.hasMore == true, response.nextPage)
        }

        return aggregateAnthropic(buckets: buckets, start: start, end: end, isTruncated: isTruncated)
    }

    // MARK: - OpenAI

    private static func fetchOpenAI(adminKey: String, start: Date, end: Date) async throws -> ApiUsage {
        let baseQueryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by", value: "model")
        ]

        let decoder = JSONDecoder()

        let (buckets, isTruncated) = try await paginate { pageToken in
            guard var components = URLComponents(
                string: "https://api.openai.com/v1/organization/usage/completions"
            ) else {
                throw ServiceError.invalidURL
            }
            var queryItems = baseQueryItems
            if let pageToken {
                queryItems.append(URLQueryItem(name: "page", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw ServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let response: OpenAIUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            return (response.data, response.hasMore == true, response.nextPage)
        }

        return aggregateOpenAI(buckets: buckets, start: start, end: end, isTruncated: isTruncated)
    }

    // MARK: - Aggregation

    static func aggregateAnthropic(
        buckets: [AnthropicUsageBucket],
        start: Date,
        end: Date,
        isTruncated: Bool = false
    ) -> ApiUsage {
        var perModel: [String: ModelTokenAccumulator] = [:]
        for bucket in buckets {
            for result in bucket.results {
                let model = result.model ?? "unknown"
                perModel[model, default: ModelTokenAccumulator()].addAnthropic(result)
            }
        }

        return aggregate(provider: .anthropic, perModel: perModel, start: start, end: end, isTruncated: isTruncated)
    }

    static func aggregateOpenAI(
        buckets: [OpenAIUsageBucket],
        start: Date,
        end: Date,
        isTruncated: Bool = false
    ) -> ApiUsage {
        var perModel: [String: ModelTokenAccumulator] = [:]
        for bucket in buckets {
            for result in bucket.results {
                let model = result.model ?? "unknown"
                perModel[model, default: ModelTokenAccumulator()].addOpenAI(result)
            }
        }

        return aggregate(provider: .openai, perModel: perModel, start: start, end: end, isTruncated: isTruncated)
    }

    private static func aggregate(
        provider: ApiProvider,
        perModel: [String: ModelTokenAccumulator],
        start: Date,
        end: Date,
        isTruncated: Bool
    ) -> ApiUsage {
        let breakdowns: [ApiModelUsage] = perModel.map { model, accumulator in
            ApiModelUsage(
                model: model,
                inputTokens: accumulator.totalInput,
                outputTokens: accumulator.output,
                estimatedCostUSD: ApiUsagePricing.cost(provider: provider, model: model, tokens: accumulator.tokens),
                isPricingUnverified: ApiUsagePricing.isPricingUnverified(provider: provider, model: model),
                hasIncompleteInputData: accumulator.hasIncompleteInputData
            )
        }
        .filter { $0.totalTokens > 0 }
        .sorted { $0.estimatedCostUSD > $1.estimatedCostUSD }

        return ApiUsage(
            provider: provider,
            windowStart: start,
            windowEnd: end,
            inputTokens: breakdowns.reduce(0) { $0 + $1.inputTokens },
            outputTokens: breakdowns.reduce(0) { $0 + $1.outputTokens },
            estimatedCostUSD: breakdowns.reduce(0) { $0 + $1.estimatedCostUSD },
            models: breakdowns,
            isTruncated: isTruncated
        )
    }
}

// MARK: - ModelTokenAccumulator

/// Per-model running totals, split into the same components
/// `ApiUsagePricing.TokenBreakdown` prices independently, so a cache-read or
/// cache-creation token is never folded into the uncached input count before
/// it reaches pricing (#537).
private struct ModelTokenAccumulator {
    private(set) var uncachedInput = 0
    private(set) var cacheRead = 0
    private(set) var cacheCreationFiveMinute = 0
    private(set) var cacheCreationOneHour = 0
    private(set) var output = 0
    /// At least one usage row contributed no input-token fields at all.
    private(set) var hasIncompleteInputData = false

    var totalInput: Int { uncachedInput + cacheRead + cacheCreationFiveMinute + cacheCreationOneHour }

    var tokens: ApiUsagePricing.TokenBreakdown {
        ApiUsagePricing.TokenBreakdown(
            uncachedInput: uncachedInput,
            cacheRead: cacheRead,
            cacheCreationFiveMinute: cacheCreationFiveMinute,
            cacheCreationOneHour: cacheCreationOneHour,
            output: output
        )
    }

    mutating func addAnthropic(_ result: AnthropicUsageResult) {
        uncachedInput += result.uncachedInputTokens ?? 0
        cacheRead += result.cacheReadInputTokens ?? 0
        cacheCreationFiveMinute += result.cacheCreation?.ephemeral5MinuteInputTokens ?? 0
        cacheCreationOneHour += result.cacheCreation?.ephemeral1HourInputTokens ?? 0
        output += result.outputTokens ?? 0
        if result.hasNoInputTokenData { hasIncompleteInputData = true }
    }

    mutating func addOpenAI(_ result: OpenAIUsageResult) {
        // `inputTokens` includes cached tokens; the cached portion is priced
        // separately, so it is subtracted back out here rather than double
        // counted as both uncached input and a cache read (#537).
        let cached = max(0, result.inputCachedTokens ?? 0)
        let total = result.inputTokens ?? 0
        uncachedInput += max(0, total - cached)
        cacheRead += cached
        output += result.outputTokens ?? 0
        if result.inputTokens == nil { hasIncompleteInputData = true }
    }
}

// MARK: - Anthropic response DTOs

struct AnthropicUsageResponse: Codable {
    let data: [AnthropicUsageBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct AnthropicUsageBucket: Codable {
    let results: [AnthropicUsageResult]
}

struct AnthropicUsageResult: Codable {
    let uncachedInputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreation: AnthropicCacheCreation?
    let outputTokens: Int?
    let model: String?

    var totalInputTokens: Int {
        (uncachedInputTokens ?? 0)
            + (cacheReadInputTokens ?? 0)
            + (cacheCreation?.ephemeral1HourInputTokens ?? 0)
            + (cacheCreation?.ephemeral5MinuteInputTokens ?? 0)
    }

    /// True when every input-token source is absent — as opposed to present
    /// and legitimately zero. A provider field rename would land here: the
    /// row keeps its `output_tokens` and would otherwise silently price as
    /// zero confident input (#537).
    var hasNoInputTokenData: Bool {
        uncachedInputTokens == nil
            && cacheReadInputTokens == nil
            && cacheCreation?.ephemeral1HourInputTokens == nil
            && cacheCreation?.ephemeral5MinuteInputTokens == nil
    }

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case outputTokens = "output_tokens"
        case model
    }
}

struct AnthropicCacheCreation: Codable {
    let ephemeral1HourInputTokens: Int?
    let ephemeral5MinuteInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral1HourInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5MinuteInputTokens = "ephemeral_5m_input_tokens"
    }
}

// MARK: - OpenAI response DTOs

struct OpenAIUsageResponse: Codable {
    let data: [OpenAIUsageBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAIUsageBucket: Codable {
    let results: [OpenAIUsageResult]
}

struct OpenAIUsageResult: Codable {
    let inputTokens: Int?
    /// The portion of `inputTokens` served from cache — priced at a
    /// discounted cache-read rate rather than the full input rate (#537).
    let inputCachedTokens: Int?
    let outputTokens: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}
