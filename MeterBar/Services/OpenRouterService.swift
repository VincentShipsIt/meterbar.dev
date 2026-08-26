import Combine
import Foundation
import MeterBarShared

/// Fetches OpenRouter account credits and optional per-key spending limits for
/// every managed API key.
///
/// Each `OpenRouterAccount` owns one Keychain item keyed by its id; the key is
/// sent only to OpenRouter's documented `/api/v1/credits` and `/api/v1/key`
/// endpoints. The legacy single-key item (`keychainKey`) doubles as the
/// default account's item, so pre-multi-key installs migrate without copying
/// or rewriting anything.
final class OpenRouterService: ObservableObject {
    nonisolated static let shared = OpenRouterService()
    /// Legacy single-key item name — now the default account's Keychain key.
    nonisolated static let keychainKey = "openRouterAPIKey"

    /// Most recent failure across all keys, cleared on any successful poll.
    /// Aggregate surface for diagnostics views; per-key detail lives in
    /// `accountLastErrors`.
    @Published private(set) var lastError: ServiceError?
    /// Per-key refresh outcome, keyed by account id. Drives the Settings rows.
    @Published private(set) var accountLastErrors: [UUID: ServiceError] = [:]

    /// Latest per-key running-spend observations from the most recent polls.
    /// `UsageDataManager` folds these into one provider-wide ledger entry.
    private(set) var latestAccountObservations: [UUID: ProviderUsageObservation] = [:]

    private let keychain: KeychainManager
    private let fetchData: @Sendable (URLRequest) async throws -> Data

    init(
        keychain: KeychainManager = .shared,
        fetchData: (@Sendable (URLRequest) async throws -> Data)? = nil
    ) {
        self.keychain = keychain
        self.fetchData = fetchData ?? Self.fetch
    }

    /// The Keychain item name for one managed key. The default account keeps
    /// the legacy single-key name so existing installs keep working unchanged.
    nonisolated static func keychainKey(for accountID: UUID) -> String {
        accountID == OpenRouterAccount.defaultID
            ? keychainKey
            : "\(keychainKey).\(accountID.uuidString)"
    }

    func hasKey(for accountID: UUID) -> Bool {
        keychain.hasKey(key: Self.keychainKey(for: accountID))
    }

    /// Whether this key participates in refreshes. Sync and prompt-free: like
    /// `KeychainManager.hasKey`, it probes attributes only and never decrypts.
    func canAccess(account: OpenRouterAccount) -> Bool {
        hasKey(for: account.id)
    }

    @discardableResult
    func saveAPIKey(_ value: String, for accountID: UUID) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, keychain.save(key: Self.keychainKey(for: accountID), value: key) else {
            return false
        }
        accountLastErrors[accountID] = nil
        // Saving one key does not heal a different key's failure, so the
        // aggregate clears only when no managed key is still failing.
        if accountLastErrors.isEmpty {
            lastError = nil
        }
        return true
    }

    @discardableResult
    func removeAPIKey(for accountID: UUID) -> Bool {
        let deleted = keychain.delete(key: Self.keychainKey(for: accountID))
        accountLastErrors[accountID] = nil
        latestAccountObservations[accountID] = nil
        if accountLastErrors.isEmpty {
            lastError = nil
        }
        return deleted
    }

    func fetchUsageMetrics(account: OpenRouterAccount) async throws -> UsageMetrics {
        guard let apiKey = keychain.get(key: Self.keychainKey(for: account.id)) else {
            let error = ServiceError.notAuthenticated
            accountLastErrors[account.id] = error
            throw error
        }

        do {
            let fetched = try await Self.fetchRemotely(apiKey: apiKey, fetchData: fetchData)
            accountLastErrors[account.id] = nil
            latestAccountObservations[account.id] = fetched.observation
            // The aggregate clears only when every managed key is healthy;
            // otherwise another key's failure remains the provider-wide state.
            if accountLastErrors.isEmpty {
                lastError = nil
            }
            return fetched.metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            accountLastErrors[account.id] = serviceError
            lastError = serviceError
            throw serviceError
        }
    }

    /// The outcome of one off-main poll, shipped back to the caller as one
    /// `Sendable` value so the main-actor side only ever touches its own
    /// `@Published` state after the network work has fully settled.
    private struct FetchedUsage: Sendable {
        let metrics: UsageMetrics
        let observation: ProviderUsageObservation
    }

    /// Runs both network legs and the decode off the main actor.
    ///
    /// The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor`, so an unannotated fetch path here would execute as
    /// main-actor jobs — and the two `async let` legs through the *stored*
    /// `fetchData` closure cross a reabstraction-thunk actor hop whose
    /// caller-owned argument buffer does not reliably survive. That is the
    /// exact hazard that crashed Settings → Codex (#328, 4a38ab6) and that
    /// crashed 1.8.37 entering `NSURLSession.data(for:delegate:)` with a dead
    /// receiver the moment a key was saved and validated. Nothing in the
    /// detached scope touches main-actor state: only `Sendable` values go in,
    /// only a `Sendable` result comes out.
    nonisolated private static func fetchRemotely(
        apiKey: String,
        fetchData: @escaping @Sendable (URLRequest) async throws -> Data
    ) async throws -> FetchedUsage {
        try await Task.detached(priority: .userInitiated) {
            async let creditsData = fetchData(try request(path: "credits", apiKey: apiKey))
            async let keyData = fetchData(try request(path: "key", apiKey: apiKey))
            let decoder = JSONDecoder()
            let credits = try decoder.decode(OpenRouterCreditsResponse.self, from: await creditsData)
            let key = try decoder.decode(OpenRouterKeyResponse.self, from: await keyData)
            let metrics = map(credits: credits.data, key: key.data)
            return FetchedUsage(
                metrics: metrics,
                observation: observation(key: key.data, at: metrics.lastUpdated)
            )
        }.value
    }

    nonisolated static func map(
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

    /// One poll's reading of the key's running spend, in dollars.
    ///
    /// Both fields are already USD — OpenRouter bills in dollars and publishes
    /// them as such — so nothing is converted here and no rate is guessed. No
    /// token counts ride along because the endpoint reports none; see
    /// `ProviderUsageCostBuilder`.
    ///
    /// Key-scoped rather than account-scoped: `usage` and `usage_daily` both
    /// describe the key MeterBar authenticates with, while `/credits` reports
    /// the whole account. Mixing the two would have the delta path and the
    /// authoritative-today path measuring different things and contradicting
    /// each other on alternating polls.
    nonisolated static func observation(key: OpenRouterKey, at observedAt: Date) -> ProviderUsageObservation {
        ProviderUsageObservation(
            provider: .openRouter,
            unit: .usd,
            runningTotal: key.usage,
            // Authoritative for the whole of today, including the hours MeterBar
            // was not running — which a delta between two polls cannot see.
            authoritativeDailyTotal: key.usageDaily,
            // `usage_daily` is documented as spend since midnight UTC, and it is
            // written into its day's bucket absolutely. Filing it under a local
            // day would both misdate it and overwrite the delta sum that day had
            // legitimately accumulated, for every user not already on UTC.
            dayBoundary: .utc,
            observedAt: observedAt
        )
    }

    /// Folds one poll's per-key readings into the single provider-wide ledger
    /// observation.
    ///
    /// Running totals simply sum — each key reports its own spend. The
    /// authoritative daily total sums only when *every* polled key published
    /// `usage_daily` (`allowsAuthoritativeDaily` additionally requires the
    /// poll itself to be complete — a key that failed this poll would make any
    /// daily sum understate the day); otherwise the delta path takes over.
    nonisolated static func aggregatedObservation(
        _ observations: [ProviderUsageObservation],
        observedAt: Date,
        allowsAuthoritativeDaily: Bool = true
    ) -> ProviderUsageObservation? {
        guard !observations.isEmpty else { return nil }
        let dailies = observations.map(\.authoritativeDailyTotal)
        let authoritativeDaily: Double? = allowsAuthoritativeDaily && !dailies.contains(nil)
            ? dailies.compactMap { $0 }.reduce(0, +)
            : nil
        return ProviderUsageObservation(
            provider: .openRouter,
            unit: .usd,
            runningTotal: observations.reduce(0) { $0 + $1.runningTotal },
            authoritativeDailyTotal: authoritativeDaily,
            dayBoundary: .utc,
            observedAt: observedAt
        )
    }

    nonisolated private static func request(path: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/\(path)") else {
            throw ServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await ServiceSupport.data(for: request)
        try ServiceSupport.validate(response, data: data)
        return data
    }

    nonisolated private static func resetWindow(
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

// `nonisolated` keeps the Codable conformances usable from the detached fetch
// scope — under default MainActor isolation they would otherwise be
// main-actor-isolated and unusable off the main actor.
nonisolated struct OpenRouterCreditsResponse: Codable {
    let data: OpenRouterCredits
}

nonisolated struct OpenRouterCredits: Codable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

nonisolated struct OpenRouterKeyResponse: Codable {
    let data: OpenRouterKey
}

nonisolated struct OpenRouterKey: Codable {
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
