import Combine
import Foundation
import MeterBarShared

/// Reads the Claude Console API credit balance and credit grants — the monthly
/// API credit a Max or Team plan includes, plus purchased credit — from the
/// `platform.claude.com` billing endpoints (`ClaudePlatformParser`).
///
/// Why a cookie: inference API keys cannot read billing and the Admin API is
/// unavailable to individual accounts, so the Console session is the only
/// credential that can read an individual organization's balance. The user
/// pastes it into Settings; MeterBar keeps only the `sessionKey` value, in its
/// own Keychain, and sends it to `platform.claude.com` alone. No browser cookie
/// store is opened and nothing is imported.
///
/// Every request is a read-only GET. Organization ids are validated before they
/// enter a path, 429/5xx surface as bare status codes, and no response body is
/// logged or kept.
final class ClaudePlatformService: ObservableObject, SimpleUsageProviding {
    nonisolated static let shared = ClaudePlatformService()
    nonisolated static let keychainKey = "claudePlatformSessionKey"
    nonisolated static let host = "platform.claude.com"

    @Published private(set) var lastError: ServiceError?
    @Published private(set) var support: ClaudePlatformAccountSupport?
    /// Plain-language balance, month-to-date spend and next expiry. In memory
    /// only: it carries billing figures.
    @Published private(set) var balanceNote: String?

    struct Response: Sendable {
        let data: Data
        let statusCode: Int
    }

    private let apiKeyStore: ProviderAPIKeyStore
    private let fetch: @Sendable (URLRequest) async throws -> Response
    private let settingsDirectory: URL?
    private let now: @Sendable () -> Date

    init(
        keychain: KeychainManager = .shared,
        fetch: (@Sendable (URLRequest) async throws -> Response)? = nil,
        settingsDirectory: URL? = SharedMetricsStore.containerURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyStore = ProviderAPIKeyStore(keychainKey: Self.keychainKey, keychain: keychain)
        self.fetch = fetch ?? Self.liveFetch
        self.settingsDirectory = settingsDirectory
        self.now = now
        self.support = ClaudePlatformSupportSetting.load(directory: settingsDirectory)
    }

    var hasSessionKey: Bool { apiKeyStore.hasKey }

    /// A session is present and the Console has not rejected it. A rejected
    /// session clears access until it is replaced, so the card asks for a fresh
    /// cookie instead of polling with one that cannot work. Prompt-free.
    var hasAccess: Bool {
        if case .notAuthenticated? = lastError { return false }
        return hasSessionKey
    }

    /// An authored explanation for an account the Console cannot report on,
    /// shown on the empty card instead of the generic setup prompt.
    var statusNote: String? {
        guard let support, !support.isReadable else { return nil }
        return support.message
    }

    /// Saves the `sessionKey` out of whatever the user pasted (a whole `Cookie`
    /// header, a `sessionKey=…` pair, or the bare value). Returns false when no
    /// usable value is in it.
    @discardableResult
    func saveSessionKey(_ pasted: String) -> Bool {
        guard let value = ClaudePlatformSessionKey.normalized(pasted), apiKeyStore.save(value) else {
            return false
        }
        objectWillChange.send()
        lastError = nil
        return true
    }

    @discardableResult
    func removeSessionKey() -> Bool {
        let removed = apiKeyStore.remove()
        objectWillChange.send()
        lastError = nil
        clearClassification()
        return removed
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let sessionKey = apiKeyStore.key(), !sessionKey.isEmpty else {
            let error = ServiceError.notAuthenticated
            lastError = error
            throw error
        }
        let fetch = fetch
        let now = now
        do {
            let outcome = try await ServiceSupport.detached {
                try await Self.resolve(sessionKey: sessionKey, fetch: fetch, now: now())
            }
            lastError = nil
            support = outcome.support
            balanceNote = outcome.note
            ClaudePlatformSupportSetting.save(outcome.support, directory: settingsDirectory)
            return outcome.metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            lastError = serviceError
            throw serviceError
        }
    }

    // MARK: - Fetch

    private struct Outcome: Sendable {
        let metrics: UsageMetrics
        let support: ClaudePlatformAccountSupport
        let note: String?
    }

    nonisolated private static func resolve(
        sessionKey: String,
        fetch: @Sendable (URLRequest) async throws -> Response,
        now: Date
    ) async throws -> Outcome {
        // The organization list doubles as the session check: a rejected
        // cookie answers 401 or 403.
        let organizations = try ClaudePlatformParser.apiOrganizations(
            try await get("/api/organizations", sessionKey: sessionKey, fetch: fetch, forbidden: .rejected)
        )
        guard !organizations.isEmpty else {
            return Outcome(metrics: emptyMetrics(now: now), support: .noAPIOrganization, note: nil)
        }

        // First API organization whose billing this member can read wins.
        for organization in organizations {
            let creditsData: Data
            do {
                creditsData = try await get(
                    "/api/organizations/\(organization.id)/prepaid/credits",
                    sessionKey: sessionKey,
                    fetch: fetch,
                    forbidden: .billingDenied
                )
            } catch Denial.billingDenied {
                continue
            }
            let credits = try ClaudePlatformParser.credits(creditsData, now: now)
            // Optional: a failed or malformed spend report keeps the balance.
            let spend = try? await get(
                "/api/organizations/\(organization.id)/current_spend",
                sessionKey: sessionKey,
                fetch: fetch,
                forbidden: .billingDenied
            )
            let reading = try ClaudePlatformParser.reading(
                credits: credits,
                monthToDateSpend: spend.flatMap {
                    ClaudePlatformParser.monthToDateSpend($0, exponent: credits.exponent)
                },
                organizationName: organization.name,
                now: now
            )
            return Outcome(
                metrics: reading.metrics,
                support: .readable,
                note: note(for: reading.summary)
            )
        }
        return Outcome(metrics: emptyMetrics(now: now), support: .billingAccessDenied, note: nil)
    }

    private enum Denial: Error {
        case rejected
        case billingDenied
    }

    /// One read-only GET. 401 is always a rejected session; 403 means what the
    /// caller says it means (rejected on the organization list, billing access
    /// on a credit request).
    nonisolated private static func get(
        _ path: String,
        sessionKey: String,
        fetch: @Sendable (URLRequest) async throws -> Response,
        forbidden: Denial
    ) async throws -> Data {
        let request = try request(path: path, sessionKey: sessionKey)
        let response = try await fetch(request)
        switch response.statusCode {
        case 200:
            return response.data
        case 401:
            throw ServiceError.notAuthenticated
        case 403:
            if forbidden == .rejected { throw ServiceError.notAuthenticated }
            throw Denial.billingDenied
        default:
            throw ServiceError.apiError("HTTP \(response.statusCode)")
        }
    }

    nonisolated static func request(path: String, sessionKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://\(host)\(path)"), url.host == host, url.scheme == "https" else {
            throw ServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout
        for (name, value) in ServiceSupport.browserHeaders(for: .claudePlatform) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("\(ClaudePlatformSessionKey.cookieName)=\(sessionKey)", forHTTPHeaderField: "Cookie")
        // The cookie is the whole credential: never let the shared session add
        // or replay others.
        request.httpShouldHandleCookies = false
        return request
    }

    nonisolated private static func liveFetch(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await ServiceSupport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.apiError("Invalid response type")
        }
        return Response(data: data, statusCode: http.statusCode)
    }

    nonisolated private static func emptyMetrics(now: Date) -> UsageMetrics {
        UsageMetrics(service: .claudePlatform, lastUpdated: now)
    }

    nonisolated static func note(for summary: ClaudePlatformParser.Summary) -> String {
        var parts = ["Balance \(UsageAmountFormat.currency(summary.balance, code: summary.currency))"]
        if let spend = summary.monthToDateSpend {
            parts.append("This month \(UsageAmountFormat.currency(spend, code: summary.currency))")
        }
        if let expiry = summary.nextExpiry {
            parts.append("Next credit expires \(expiryText(expiry))")
        }
        if let organization = summary.organizationName {
            parts.append(organization)
        }
        return parts.joined(separator: " · ")
    }

    /// Console grants expire at UTC midnight; show that UTC calendar date
    /// instead of shifting it into the local zone.
    nonisolated static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: date)) (UTC)"
    }

    private func clearClassification() {
        support = nil
        balanceNote = nil
        ClaudePlatformSupportSetting.save(nil, directory: settingsDirectory)
    }
}
