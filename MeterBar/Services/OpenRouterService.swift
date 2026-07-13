import Combine
import Foundation
import MeterBarShared

/// Fetches OpenRouter account credits and optional per-key spending limits.
/// The API key is stored in MeterBar's Keychain service and is only sent to
/// OpenRouter's documented `/api/v1/credits` and `/api/v1/key` endpoints.
final class OpenRouterService: ObservableObject {
    nonisolated static let shared = OpenRouterService()
    nonisolated static let keychainKey = "openRouterAPIKey"

    @Published private(set) var hasAccess: Bool
    @Published private(set) var lastError: ServiceError?

    private let keychain: KeychainManager
    private let fetchData: (URLRequest) async throws -> Data

    init(
        keychain: KeychainManager = .shared,
        fetchData: ((URLRequest) async throws -> Data)? = nil
    ) {
        self.keychain = keychain
        self.fetchData = fetchData ?? Self.fetch
        hasAccess = keychain.hasKey(key: Self.keychainKey)
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, keychain.save(key: Self.keychainKey, value: key) else {
            return false
        }
        hasAccess = true
        lastError = nil
        return true
    }

    @discardableResult
    func removeAPIKey() -> Bool {
        let deleted = keychain.delete(key: Self.keychainKey)
        hasAccess = keychain.hasKey(key: Self.keychainKey)
        if !hasAccess {
            lastError = nil
        }
        return deleted
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let apiKey = keychain.get(key: Self.keychainKey) else {
            let error = ServiceError.notAuthenticated
            lastError = error
            hasAccess = false
            throw error
        }

        do {
            async let creditsData = fetchData(try Self.request(path: "credits", apiKey: apiKey))
            async let keyData = fetchData(try Self.request(path: "key", apiKey: apiKey))
            let decoder = JSONDecoder()
            let credits = try decoder.decode(OpenRouterCreditsResponse.self, from: await creditsData)
            let key = try decoder.decode(OpenRouterKeyResponse.self, from: await keyData)
            let metrics = Self.map(credits: credits.data, key: key.data)
            hasAccess = true
            lastError = nil
            return metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            lastError = serviceError
            if case .notAuthenticated = serviceError {
                hasAccess = false
            }
            throw serviceError
        }
    }

    static func map(
        credits: OpenRouterCredits,
        key: OpenRouterKey,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> UsageMetrics {
        let accountCredits = UsageLimit(
            used: credits.totalUsage,
            total: credits.totalCredits,
            resetTime: nil
        )

        let keyLimit: UsageLimit? = {
            guard let limit = key.limit, limit > 0 else { return nil }
            let used = key.limitRemaining.map { max(0, limit - $0) } ?? min(key.usage, limit)
            let reset = resetWindow(key.limitReset, now: now, calendar: calendar)
            return UsageLimit(
                used: used,
                total: limit,
                resetTime: reset.date,
                windowSeconds: reset.windowSeconds
            )
        }()

        return UsageMetrics(
            service: .openRouter,
            sessionLimit: keyLimit,
            weeklyLimit: accountCredits,
            lastUpdated: now
        )
    }

    private static func request(path: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/\(path)") else {
            throw ServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await ServiceSupport.session.data(for: request)
        try ServiceSupport.validate(response, data: data)
        return data
    }

    private static func resetWindow(
        _ rawValue: String?,
        now: Date,
        calendar: Calendar
    ) -> (date: Date?, windowSeconds: TimeInterval?) {
        guard let rawValue else { return (nil, nil) }
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        switch rawValue.lowercased() {
        case "daily":
            let start = utc.startOfDay(for: now)
            return (utc.date(byAdding: .day, value: 1, to: start), 86_400)
        case "weekly":
            let start = utc.dateInterval(of: .weekOfYear, for: now)?.start
            return (start.flatMap { utc.date(byAdding: .weekOfYear, value: 1, to: $0) }, 604_800)
        case "monthly":
            let start = utc.dateInterval(of: .month, for: now)?.start
            return (start.flatMap { utc.date(byAdding: .month, value: 1, to: $0) }, nil)
        default:
            return (nil, nil)
        }
    }
}

struct OpenRouterCreditsResponse: Codable {
    let data: OpenRouterCredits
}

struct OpenRouterCredits: Codable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

struct OpenRouterKeyResponse: Codable {
    let data: OpenRouterKey
}

struct OpenRouterKey: Codable {
    let label: String?
    let limit: Double?
    let limitReset: String?
    let limitRemaining: Double?
    let usage: Double
    let usageDaily: Double?
    let usageWeekly: Double?
    let usageMonthly: Double?
    let isFreeTier: Bool?

    enum CodingKeys: String, CodingKey {
        case label
        case limit
        case limitReset = "limit_reset"
        case limitRemaining = "limit_remaining"
        case usage
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case isFreeTier = "is_free_tier"
    }
}
