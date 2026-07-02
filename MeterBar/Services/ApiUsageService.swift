import Foundation

/// Fetches organization API usage (per-model token counts) from the Anthropic
/// and OpenAI admin usage endpoints, aggregates it over a window, and prices it
/// into an `ApiUsage`. Unlike the subscription providers there is no quota — the
/// card shows real spend and tokens, not a percentage.
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
        var buckets: [AnthropicUsageBucket] = []
        var nextPage: String?
        var pagesFetched = 0

        repeat {
            guard var components = URLComponents(
                string: "https://api.anthropic.com/v1/organizations/usage_report/messages"
            ) else {
                throw ServiceError.invalidURL
            }
            var queryItems = baseQueryItems
            if let nextPage {
                queryItems.append(URLQueryItem(name: "page", value: nextPage))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw ServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let response: AnthropicUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            buckets.append(contentsOf: response.data)
            nextPage = (response.hasMore == true) ? response.nextPage : nil
            pagesFetched += 1
        } while nextPage != nil && pagesFetched < maxUsagePages

        var perModelInput: [String: Int] = [:]
        var perModelOutput: [String: Int] = [:]
        for bucket in buckets {
            let model = bucket.model ?? "unknown"
            perModelInput[model, default: 0] += (bucket.inputTokens ?? 0) + (bucket.cacheCreationInputTokens ?? 0)
            perModelOutput[model, default: 0] += bucket.outputTokens ?? 0
        }

        return aggregate(provider: .anthropic, input: perModelInput, output: perModelOutput, start: start, end: end)
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
        var buckets: [OpenAIUsageBucket] = []
        var nextPage: String?
        var pagesFetched = 0

        repeat {
            guard var components = URLComponents(
                string: "https://api.openai.com/v1/organization/usage/completions"
            ) else {
                throw ServiceError.invalidURL
            }
            var queryItems = baseQueryItems
            if let nextPage {
                queryItems.append(URLQueryItem(name: "page", value: nextPage))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw ServiceError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let response: OpenAIUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            buckets.append(contentsOf: response.data)
            nextPage = (response.hasMore == true) ? response.nextPage : nil
            pagesFetched += 1
        } while nextPage != nil && pagesFetched < maxUsagePages

        var perModelInput: [String: Int] = [:]
        var perModelOutput: [String: Int] = [:]
        for bucket in buckets {
            for result in bucket.results {
                let model = result.model ?? "unknown"
                perModelInput[model, default: 0] += result.inputTokens ?? 0
                perModelOutput[model, default: 0] += result.outputTokens ?? 0
            }
        }

        return aggregate(provider: .openai, input: perModelInput, output: perModelOutput, start: start, end: end)
    }

    // MARK: - Aggregation

    private static func aggregate(
        provider: ApiProvider,
        input: [String: Int],
        output: [String: Int],
        start: Date,
        end: Date
    ) -> ApiUsage {
        let models = Set(input.keys).union(output.keys)
        let breakdowns: [ApiModelUsage] = models.map { model in
            let modelInput = input[model] ?? 0
            let modelOutput = output[model] ?? 0
            return ApiModelUsage(
                model: model,
                inputTokens: modelInput,
                outputTokens: modelOutput,
                estimatedCostUSD: ApiUsagePricing.cost(
                    provider: provider,
                    model: model,
                    inputTokens: modelInput,
                    outputTokens: modelOutput
                )
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
            models: breakdowns
        )
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
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case model
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
    let outputTokens: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}
