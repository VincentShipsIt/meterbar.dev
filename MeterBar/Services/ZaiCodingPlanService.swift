import Combine
import Foundation
import MeterBarShared

/// Fetches GLM Coding Plan quota from Z.ai's monitor endpoint,
/// `GET https://<region host>/api/monitor/usage/quota/limit`.
///
/// One user-supplied Coding Plan key, held in MeterBar's Keychain (nothing is
/// scraped from a shell profile or another tool's config). The host comes from
/// a closed `ZaiCodingPlanRegion` choice, never from user text. Requests use
/// the shared ephemeral session and carry only the key, `Accept`, and
/// `Accept-Language` — the same three headers the official plugin sends,
/// including its unprefixed `Authorization` value.
///
/// Source: Z.ai's official usage-query plugin
/// (`zai-org/zai-coding-plugins`). First-party, but the monitor endpoints are
/// not a separately versioned REST contract, so `ZaiCodingPlanUsageParser` is
/// fixture-tested and reports a parse failure instead of 0% on drift. The
/// plugin's `model-usage` and `tool-usage` endpoints are deliberately not
/// called: they return per-model token and per-tool call counts with no limit
/// to compare against, and MeterBar has nothing honest to draw from them.
final class ZaiCodingPlanService: ObservableObject, SimpleUsageProviding {
    nonisolated static let shared = ZaiCodingPlanService()
    nonisolated static let keychainKey = "zaiCodingPlanAPIKey"

    @Published private(set) var lastError: ServiceError?
    /// The plan tier the last response named (`lite`, `pro`, `max`), for the
    /// Settings Plan row. Never used to derive a quota.
    @Published private(set) var planName: String?

    private let apiKeyStore: ProviderAPIKeyStore
    private let fetchData: @Sendable (URLRequest) async throws -> Data
    private let region: @Sendable () -> ZaiCodingPlanRegion
    private let now: @Sendable () -> Date

    init(
        keychain: KeychainManager = .shared,
        fetchData: (@Sendable (URLRequest) async throws -> Data)? = nil,
        region: @escaping @Sendable () -> ZaiCodingPlanRegion = { ZaiRegionSetting.current() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyStore = ProviderAPIKeyStore(keychainKey: Self.keychainKey, keychain: keychain)
        self.fetchData = fetchData ?? ServiceSupport.fetchValidatedData
        self.region = region
        self.now = now
    }

    var hasAPIKey: Bool { apiKeyStore.hasKey }

    /// A key is present and Z.ai has not rejected it. A rejected key clears
    /// access until it is replaced, so the card asks for a new key instead of
    /// polling with one that cannot work. Sync and prompt-free: an
    /// attribute-only Keychain probe.
    var hasAccess: Bool {
        if case .notAuthenticated? = lastError { return false }
        return hasAPIKey
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        guard apiKeyStore.save(value) else { return false }
        objectWillChange.send()
        lastError = nil
        return true
    }

    @discardableResult
    func removeAPIKey() -> Bool {
        let removed = apiKeyStore.remove()
        objectWillChange.send()
        lastError = nil
        planName = nil
        return removed
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let apiKey = apiKeyStore.key(), !apiKey.isEmpty else {
            let error = ServiceError.notAuthenticated
            lastError = error
            throw error
        }
        let region = region()
        let fetchData = fetchData
        let now = now
        do {
            let result = try await ServiceSupport.detached {
                let data = try await fetchData(try Self.request(apiKey: apiKey, region: region))
                return try ZaiCodingPlanUsageParser.parse(data, now: now())
            }
            lastError = nil
            planName = result.plan
            return result.metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            lastError = serviceError
            throw serviceError
        }
    }

    nonisolated static func request(apiKey: String, region: ZaiCodingPlanRegion) throws -> URLRequest {
        guard let url = region.quotaLimitURL else { throw ServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        return request
    }
}
