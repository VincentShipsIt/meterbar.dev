import Foundation
import MeterBarShared
import Combine

class ClaudeService {
    static let shared = ClaudeService()

    private let authManager = AuthenticationManager.shared
    private let baseURL = "https://api.anthropic.com"

    private init() {}

    /// Safety cap on pagination so a misbehaving API can never loop forever.
    private let maxUsagePages = 50

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let adminKey = authManager.claudeAdminKey else {
            throw ServiceError.notAuthenticated
        }

        // Calculate time range: last 7 days
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate) ?? endDate

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let startingAt = dateFormatter.string(from: startDate)
        let endingAt = dateFormatter.string(from: endDate)

        let baseQueryItems = [
            URLQueryItem(name: "starting_at", value: startingAt),
            URLQueryItem(name: "ending_at", value: endingAt),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by[]", value: "model")
        ]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Follow pagination: the usage report can return multiple pages, and
        // ignoring `has_more`/`next_page` silently under-counts usage.
        var allBuckets: [AnthropicUsageBucket] = []
        var nextPage: String?
        var pagesFetched = 0

        repeat {
            guard var components = URLComponents(string: "\(baseURL)/v1/organizations/usage_report/messages") else {
                throw ServiceError.invalidURL
            }
            var queryItems = baseQueryItems
            if let nextPage {
                queryItems.append(URLQueryItem(name: "page", value: nextPage))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw ServiceError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let responseData: AnthropicUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            allBuckets.append(contentsOf: responseData.data)
            nextPage = (responseData.hasMore == true) ? responseData.nextPage : nil
            pagesFetched += 1
        } while nextPage != nil && pagesFetched < maxUsagePages

        // Aggregate all usage data
        var totalInputTokens: Double = 0
        var totalOutputTokens: Double = 0

        for bucket in allBuckets {
            totalInputTokens += Double(bucket.inputTokens ?? 0)
            totalOutputTokens += Double(bucket.outputTokens ?? 0)
        }

        let totalTokens = totalInputTokens + totalOutputTokens

        // Create usage metrics
        // Note: Anthropic doesn't have fixed "limits" - this shows actual usage
        let weeklyUsage = UsageLimit(
            used: totalTokens,
            total: max(totalTokens * 1.5, 1000000), // Show relative to usage or 1M baseline
            resetTime: Calendar.current.date(byAdding: .day, value: 7, to: startDate)
        )

        return UsageMetrics(
            service: .claude,
            sessionLimit: nil, // Anthropic doesn't have session limits
            weeklyLimit: weeklyUsage,
            codeReviewLimit: nil
        )
    }
}

// MARK: - Response Models

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
    let bucketStartTime: String?
    let bucketEndTime: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let inputCachedTokens: Int?
    let cacheCreationInputTokens: Int?
    let model: String?
    let workspaceId: String?

    enum CodingKeys: String, CodingKey {
        case bucketStartTime = "bucket_start_time"
        case bucketEndTime = "bucket_end_time"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case model
        case workspaceId = "workspace_id"
    }
}

enum ServiceError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case apiError(String)
    case parsingError

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please set up your Admin API key in settings."
        case .invalidURL:
            return "Invalid URL"
        case .apiError(let message):
            return message
        case .parsingError:
            return "Failed to parse response"
        }
    }
}
