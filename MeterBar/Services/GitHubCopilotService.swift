import Combine
import Foundation
import MeterBarShared

/// Reads GitHub Copilot AI-credit billing through GitHub's documented, versioned
/// REST endpoints (`X-GitHub-Api-Version: 2026-03-10`) with a user-provided
/// fine-grained token held in MeterBar's Keychain.
///
/// **Bounded coverage, on purpose.** GitHub documents usage reports but no single
/// allowance for every plan (`GitHubCopilotAccountSupport`):
///
/// | Account | Read | Result |
/// |---|---|---|
/// | Organization-managed, billing role, user-level budget | budget `effective_budget` | quota bar (`.quota`) |
/// | Organization-managed, no user-level budget | budgets | usage-only, no cap |
/// | Personal AI-credit plan | `ai_credit/usage` | usage-only, no documented allowance |
/// | Legacy premium requests | `premium_request/usage` | usage-only, entitlement undocumented |
/// | 403 / 404 | — | unsupported, with the reason |
///
/// Only usage-only and unsupported accounts are told so precisely; no allowance
/// is guessed, nothing is inferred from Copilot's CLI UI or statusline text, and
/// no undocumented Copilot endpoint is called. Copilot CLI OAuth credentials are
/// never read or reused. The token goes only to `api.github.com`; the account
/// logins in the request path are validated (`GitHubLogin`) first.
final class GitHubCopilotService: ObservableObject, SimpleUsageProviding {
    nonisolated static let shared = GitHubCopilotService()
    nonisolated static let keychainKey = "githubCopilotToken"
    nonisolated static let apiVersion = "2026-03-10"
    nonisolated static let host = "https://api.github.com"
    /// Budget pages to read before giving up; each holds up to 100 budgets.
    nonisolated static let maximumBudgetPages = 5

    @Published private(set) var lastError: ServiceError?
    /// The last classification. Also persisted (as a token) for the CLI.
    @Published private(set) var support: GitHubCopilotAccountSupport?
    /// Plain-language state for accounts without a quota bar, including the
    /// month's readable usage. In memory only: it carries billing figures.
    @Published private(set) var supportNote: String?
    @Published private(set) var configuration: GitHubCopilotAccountConfig
    private(set) var latestUsageObservation: ProviderUsageObservation?

    private let apiKeyStore: ProviderAPIKeyStore
    private let fetchData: @Sendable (URLRequest) async throws -> Data
    private let settingsDirectory: URL?
    private let now: @Sendable () -> Date

    init(
        keychain: KeychainManager = .shared,
        fetchData: (@Sendable (URLRequest) async throws -> Data)? = nil,
        configuration: GitHubCopilotAccountConfig? = nil,
        settingsDirectory: URL? = SharedMetricsStore.containerURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyStore = ProviderAPIKeyStore(keychainKey: Self.keychainKey, keychain: keychain)
        self.fetchData = fetchData ?? ServiceSupport.fetchValidatedData
        self.settingsDirectory = settingsDirectory
        self.now = now
        self.configuration = configuration ?? GitHubCopilotAccountConfig.load(directory: settingsDirectory)
        self.support = GitHubCopilotAccountConfig.loadSupport(directory: settingsDirectory)
    }

    // MARK: - Configuration

    var hasToken: Bool { apiKeyStore.hasKey }

    /// A token, a complete account, and no rejection by GitHub. A rejected token
    /// clears access until it is replaced.
    var hasAccess: Bool {
        if case .notAuthenticated? = lastError { return false }
        return hasToken && configuration.isComplete
    }

    func saveConfiguration(_ newValue: GitHubCopilotAccountConfig) {
        var sanitized = newValue
        sanitized.username = newValue.username.flatMap { GitHubLogin.isValid($0) ? $0 : nil }
        sanitized.organization = newValue.organization.flatMap { GitHubLogin.isValid($0) ? $0 : nil }
        sanitized.save(directory: settingsDirectory)
        objectWillChange.send()
        configuration = sanitized
        clearClassification()
    }

    @discardableResult
    func saveToken(_ value: String) -> Bool {
        guard apiKeyStore.save(value) else { return false }
        objectWillChange.send()
        lastError = nil
        return true
    }

    @discardableResult
    func removeToken() -> Bool {
        let removed = apiKeyStore.remove()
        objectWillChange.send()
        lastError = nil
        clearClassification()
        return removed
    }

    private func clearClassification() {
        support = nil
        supportNote = nil
        latestUsageObservation = nil
        GitHubCopilotAccountConfig.saveSupport(nil, directory: settingsDirectory)
    }

    // MARK: - Fetch

    private struct Outcome: Sendable {
        let metrics: UsageMetrics
        let support: GitHubCopilotAccountSupport
        let note: String?
        let observation: ProviderUsageObservation?
    }

    func fetchUsageMetrics() async throws -> UsageMetrics {
        guard let token = apiKeyStore.key(), !token.isEmpty, configuration.isComplete else {
            let error = ServiceError.notAuthenticated
            lastError = error
            throw error
        }
        let configuration = configuration
        let fetchData = fetchData
        let now = now
        do {
            let outcome = try await ServiceSupport.detached {
                try await Self.resolve(token: token, configuration: configuration, fetchData: fetchData, now: now())
            }
            lastError = nil
            support = outcome.support
            supportNote = outcome.note
            latestUsageObservation = outcome.observation
            GitHubCopilotAccountConfig.saveSupport(outcome.support, directory: settingsDirectory)
            return outcome.metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            lastError = serviceError
            throw serviceError
        }
    }

    nonisolated private static func resolve(
        token: String,
        configuration: GitHubCopilotAccountConfig,
        fetchData: @Sendable (URLRequest) async throws -> Data,
        now: Date
    ) async throws -> Outcome {
        guard let username = configuration.username else { throw ServiceError.notAuthenticated }
        let month = billingMonth(containing: now)
        switch configuration.scope {
        case .personal:
            return try await resolvePersonal(
                username: username, token: token, month: month, fetchData: fetchData, now: now
            )
        case .organization:
            guard let organization = configuration.organization else { throw ServiceError.notAuthenticated }
            return try await resolveOrganization(
                organization: organization,
                username: username,
                token: token,
                month: month,
                fetchData: fetchData,
                now: now
            )
        }
    }

    // MARK: Personal

    nonisolated private static func resolvePersonal(
        username: String,
        token: String,
        month: BillingMonth,
        fetchData: @Sendable (URLRequest) async throws -> Data,
        now: Date
    ) async throws -> Outcome {
        let query = [
            URLQueryItem(name: "year", value: String(month.year)),
            URLQueryItem(name: "month", value: String(month.month))
        ]
        let creditsPath = "/users/\(username)/settings/billing/ai_credit/usage"
        let premiumPath = "/users/\(username)/settings/billing/premium_request/usage"

        let credits = try await attempt {
            try GitHubCopilotBillingParser.usage(
                from: try await fetchData(try request(path: creditsPath, query: query, token: token)),
                unit: .credits
            )
        }
        if case let .value(totals) = credits, totals.hasUsage {
            return usageOnly(.noDocumentedAllowance, totals: totals, unit: .credits, now: now)
        }

        let premium = try await attempt {
            try GitHubCopilotBillingParser.usage(
                from: try await fetchData(try request(path: premiumPath, query: query, token: token)),
                unit: .requests
            )
        }
        if case let .value(totals) = premium, totals.hasUsage {
            return usageOnly(.legacyEntitlementUndocumented, totals: totals, unit: .requests, now: now)
        }

        // Neither report shows usage. An empty report is a real answer; a
        // refusal is the first refusal's reason.
        switch (credits, premium) {
        case (.value, _), (_, .value):
            return emptyOutcome(.usageOnly(.noPersonalUsage), now: now)
        case let (.refused(status), _):
            return emptyOutcome(.unsupported(reason(forStatus: status)), now: now)
        }
    }

    // MARK: Organization

    nonisolated private static func resolveOrganization(
        organization: String,
        username: String,
        token: String,
        month: BillingMonth,
        fetchData: @Sendable (URLRequest) async throws -> Data,
        now: Date
    ) async throws -> Outcome {
        var pages: [GitHubCopilotBillingParser.BudgetsPage] = []
        for page in 1...maximumBudgetPages {
            let query = [
                URLQueryItem(name: "user", value: username),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            let path = "/organizations/\(organization)/settings/billing/budgets"
            let attempted = try await attempt {
                let body = try await fetchData(try request(path: path, query: query, token: token))
                return try GitHubCopilotBillingParser.budgets(from: body)
            }
            switch attempted {
            case let .refused(status):
                return emptyOutcome(.unsupported(reason(forStatus: status)), now: now)
            case let .value(parsed):
                pages.append(parsed)
            }
            if pages.last?.hasNextPage != true { break }
        }

        switch GitHubCopilotBillingParser.classify(pages) {
        case let .support(support):
            return emptyOutcome(support, now: now)
        case let .quota(used, total):
            let limit = UsageLimit(
                used: used,
                total: total,
                resetTime: month.nextStart,
                windowSeconds: month.nextStart.timeIntervalSince(month.start),
                periodKind: .monthly
            )
            return Outcome(
                metrics: UsageMetrics(service: .githubCopilot, weeklyLimit: limit, lastUpdated: now),
                support: .quota,
                note: nil,
                // Dollars consumed against the budget, as GitHub reports them.
                observation: ProviderUsageObservation(
                    provider: .githubCopilot,
                    unit: .usd,
                    runningTotal: used,
                    dayBoundary: .utc,
                    observedAt: now
                )
            )
        }
    }

    // MARK: Outcomes

    nonisolated private static func emptyOutcome(_ support: GitHubCopilotAccountSupport, now: Date) -> Outcome {
        Outcome(
            metrics: UsageMetrics(service: .githubCopilot, lastUpdated: now),
            support: support,
            note: support.message,
            observation: nil
        )
    }

    nonisolated private static func usageOnly(
        _ reason: GitHubCopilotAccountSupport.UsageOnlyReason,
        totals: GitHubCopilotBillingParser.UsageTotals,
        unit: GitHubCopilotBillingParser.Unit,
        now: Date
    ) -> Outcome {
        let support = GitHubCopilotAccountSupport.usageOnly(reason)
        let quantity = Int(totals.grossQuantity.rounded())
        let label = unit == .credits ? "AI credits" : "premium requests"
        let billed = ExtraUsageStatus.formatAmount(totals.netAmount, currency: "USD")
        return Outcome(
            metrics: UsageMetrics(service: .githubCopilot, lastUpdated: now),
            support: support,
            note: "\(support.message) This month: \(quantity) \(label) used, \(billed) billed.",
            observation: nil
        )
    }

    nonisolated private static func reason(forStatus status: Int) -> GitHubCopilotAccountSupport.UnsupportedReason {
        status == 403 ? .missingPermission : .notAvailable
    }

    // MARK: Requests

    private enum Attempt<T> {
        case value(T)
        /// 403 or 404: an answer about the account, not a failure of the poll.
        case refused(Int)
    }

    /// Runs one documented call. 403 and 404 classify the account; a bad token
    /// (401) and every other failure propagate as errors.
    nonisolated private static func attempt<T>(_ body: () async throws -> T) async throws -> Attempt<T> {
        do {
            return .value(try await body())
        } catch ServiceError.apiError(let message) where message == "HTTP 403" || message == "HTTP 404" {
            return .refused(message == "HTTP 403" ? 403 : 404)
        }
    }

    nonisolated static func request(
        path: String,
        query: [URLQueryItem],
        token: String
    ) throws -> URLRequest {
        var components = URLComponents(string: host + path)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url, url.host == "api.github.com", url.scheme == "https" else {
            throw ServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServiceSupport.usageRequestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub rejects requests without a User-Agent.
        request.setValue("MeterBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: Billing month

    struct BillingMonth: Equatable {
        let year: Int
        let month: Int
        let start: Date
        let nextStart: Date
    }

    /// The calendar month containing `date`, in UTC — the period GitHub's usage
    /// reports and monthly budgets are cut on.
    nonisolated static func billingMonth(containing date: Date) -> BillingMonth {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: parts) ?? date
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86_400)
        return BillingMonth(year: parts.year ?? 0, month: parts.month ?? 0, start: start, nextStart: next)
    }
}
