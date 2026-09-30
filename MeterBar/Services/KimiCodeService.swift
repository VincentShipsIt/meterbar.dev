import Combine
import Foundation
import MeterBarShared

/// Fetches Kimi Code quota from the managed `GET /coding/v1/usages` endpoint.
///
/// Credentials, in order: the official OAuth artifact (read-only, see
/// `KimiCodeCredentialReader`), then an optional API key from MeterBar's
/// Keychain. When both exist and the OAuth token is rejected, the key gets one
/// try before the failure is reported. Only the canonical managed host is
/// contacted, over an ephemeral session, with just an `Authorization` and an
/// `Accept` header — no prompt, code, or account payload is ever sent.
///
/// Source: the official open-source Kimi Code client
/// (`packages/oauth/src/managed-usage.ts`). First-party, but the endpoint is
/// not an independently versioned public API, so `KimiCodeUsageParser` is
/// fixture-tested and fails honestly instead of reporting 0% on drift.
final class KimiCodeService: ObservableObject, SimpleUsageProviding {
    nonisolated static let shared = KimiCodeService()
    nonisolated static let keychainKey = "kimiCodeAPIKey"
    nonisolated static let usageEndpoint = "https://api.kimi.com/coding/v1/usages"

    @Published private(set) var lastError: ServiceError?

    private let apiKeyStore: ProviderAPIKeyStore
    private let fetchData: @Sendable (URLRequest) async throws -> Data
    private let environment: [String: String]
    private let realHomeDirectory: String
    private let now: @Sendable () -> Date

    init(
        keychain: KeychainManager = .shared,
        fetchData: (@Sendable (URLRequest) async throws -> Data)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyStore = ProviderAPIKeyStore(keychainKey: Self.keychainKey, keychain: keychain)
        self.fetchData = fetchData ?? ServiceSupport.fetchValidatedData
        self.environment = environment
        self.realHomeDirectory = realHomeDirectory
        self.now = now
    }

    // MARK: - Credentials

    var hasAPIKey: Bool { apiKeyStore.hasKey }

    /// Sync and prompt-free: an existence check on the OAuth file plus an
    /// attribute-only Keychain probe. Whether the credential is still valid is
    /// decided by the fetch.
    var hasAccess: Bool {
        hasAPIKey || KimiCodeCredentialReader.credentialFileExists(
            environment: environment,
            realHomeDirectory: realHomeDirectory
        )
    }

    /// What is on disk, without exposing it. Reads the file, so call it off the
    /// main actor.
    nonisolated func credentialProbe() -> KimiCodeCredentialProbe {
        KimiCodeCredentialReader.read(
            environment: environment,
            realHomeDirectory: realHomeDirectory,
            now: now()
        ).probe
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
        return removed
    }

    // MARK: - Fetch

    func fetchUsageMetrics() async throws -> UsageMetrics {
        let apiKey = apiKeyStore.key()
        let environment = environment
        let realHomeDirectory = realHomeDirectory
        let fetchData = fetchData
        let now = now
        do {
            let metrics = try await ServiceSupport.detached {
                try await Self.fetchRemotely(
                    apiKey: apiKey,
                    environment: environment,
                    realHomeDirectory: realHomeDirectory,
                    fetchData: fetchData,
                    now: now()
                )
            }
            lastError = nil
            return metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            lastError = serviceError
            throw serviceError
        }
    }

    /// Runs the credential read, the request, and the decode off the main
    /// actor — see `ServiceSupport.detached`. Only `Sendable` values enter and
    /// leave the detached scope.
    nonisolated private static func fetchRemotely(
        apiKey: String?,
        environment: [String: String],
        realHomeDirectory: String,
        fetchData: @Sendable (URLRequest) async throws -> Data,
        now: Date
    ) async throws -> UsageMetrics {
        var candidates: [String] = []
        if case let .token(token) = KimiCodeCredentialReader.read(
            environment: environment,
            realHomeDirectory: realHomeDirectory,
            now: now
        ) {
            candidates.append(token)
        }
        if let apiKey, !apiKey.isEmpty {
            candidates.append(apiKey)
        }
        guard !candidates.isEmpty else { throw ServiceError.notAuthenticated }

        var rejected: ServiceError?
        for credential in candidates {
            do {
                let data = try await fetchData(try request(bearer: credential))
                return try KimiCodeUsageParser.metrics(from: data, now: now)
            } catch ServiceError.notAuthenticated {
                rejected = .notAuthenticated
            }
        }
        throw rejected ?? ServiceError.notAuthenticated
    }

    nonisolated private static func request(bearer: String) throws -> URLRequest {
        guard let url = URL(string: usageEndpoint) else { throw ServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
