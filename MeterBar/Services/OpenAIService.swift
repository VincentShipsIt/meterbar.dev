import Foundation
import MeterBarShared
import Combine

class OpenAIService {
    static let shared = OpenAIService()

    private let authManager = AuthenticationManager.shared
    private let baseURL = "https://api.openai.com"

    private init() {}

    /// Safety cap on pagination so a misbehaving API can never loop forever.
    private let maxUsagePages = 50

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let adminKey = authManager.openaiAdminKey else {
            throw ServiceError.notAuthenticated
        }

        // Calculate time range: last 7 days (Unix timestamps)
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate) ?? endDate

        let startTime = Int(startDate.timeIntervalSince1970)
        let endTime = Int(endDate.timeIntervalSince1970)

        let baseQueryItems = [
            URLQueryItem(name: "start_time", value: String(startTime)),
            URLQueryItem(name: "end_time", value: String(endTime)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by", value: "model")
        ]

        let decoder = JSONDecoder()

        // Follow pagination: ignoring `has_more`/`next_page` silently under-counts
        // usage when the 7-day window spans more than one page of buckets.
        var allBuckets: [OpenAIUsageBucket] = []
        var nextPage: String?
        var pagesFetched = 0

        repeat {
            guard var components = URLComponents(string: "\(baseURL)/v1/organization/usage/completions") else {
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
            request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let responseData: OpenAIUsageResponse = try await ServiceSupport.fetchDecoded(request, decoder: decoder)
            allBuckets.append(contentsOf: responseData.data)
            nextPage = (responseData.hasMore == true) ? responseData.nextPage : nil
            pagesFetched += 1
        } while nextPage != nil && pagesFetched < maxUsagePages

        // Aggregate all usage data
        var totalInputTokens: Double = 0
        var totalOutputTokens: Double = 0

        for bucket in allBuckets {
            for result in bucket.results {
                totalInputTokens += Double(result.inputTokens ?? 0)
                totalOutputTokens += Double(result.outputTokens ?? 0)
            }
        }

        let totalTokens = totalInputTokens + totalOutputTokens

        // Create usage metrics
        // Note: OpenAI doesn't have fixed "limits" in the usage API - this shows actual usage
        let weeklyUsage = UsageLimit(
            used: totalTokens,
            total: max(totalTokens * 1.5, 1000000), // Show relative to usage or 1M baseline
            resetTime: Calendar.current.date(byAdding: .day, value: 7, to: startDate)
        )

        return UsageMetrics(
            service: .openai,
            sessionLimit: nil,
            weeklyLimit: weeklyUsage,
            codeReviewLimit: nil
        )
    }
}

// MARK: - Response Models

struct OpenAIUsageResponse: Codable {
    let object: String?
    let data: [OpenAIUsageBucket]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct OpenAIUsageBucket: Codable {
    let object: String?
    let startTime: Int?
    let endTime: Int?
    let results: [OpenAIUsageResult]

    enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAIUsageResult: Codable {
    let object: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let inputCachedTokens: Int?
    let inputAudioTokens: Int?
    let outputAudioTokens: Int?
    let numModelRequests: Int?
    let projectId: String?
    let userId: String?
    let apiKeyId: String?
    let model: String?
    let batch: Bool?

    enum CodingKeys: String, CodingKey {
        case object
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case projectId = "project_id"
        case userId = "user_id"
        case apiKeyId = "api_key_id"
        case model
        case batch
    }
}
