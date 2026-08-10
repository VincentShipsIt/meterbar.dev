import Foundation
import MeterBarShared
import AppKit
import Combine
import os

/// Service for fetching Codex CLI usage data from https://chatgpt.com/backend-api/wham/usage
/// Reads the authentication token from `CODEX_HOME/auth.json` (stored by Codex
/// CLI; `CODEX_HOME` defaults to `~/.codex`).
/// Similar to ClaudeCodeLocalService, but for Codex CLI usage tracking.
///
/// The API endpoint returns usage data with:
/// - Short window: normally a 5-hour limit (18000 seconds)
/// - Long window: normally a 7-day limit (604800 seconds)
/// - Code review rate limit: 7-day limit for code review features
///
/// The short/long windows have historically occupied `primary_window` and
/// `secondary_window`, respectively. Their positions are not stable when OpenAI
/// disables one window, so mapping uses each window's reported duration.
class CodexCliLocalService: ObservableObject {
    static let shared = CodexCliLocalService()

    // ChatGPT Codex endpoints used by the installed Codex CLI/app-server.
    private let usageEndpoint = "https://chatgpt.com/backend-api/wham/usage"
    private let resetCreditsEndpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private let consumeResetCreditEndpoint =
        "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"

    // Shared URLSession with the standard usage-request timeouts
    private let urlSession: URLSession

    /// Raw bytes of `CODEX_HOME/auth.json`, behind a closure so tests can supply a
    /// fixture without a real credential file on disk (the auth file never
    /// exists on CI). Defaults to reading the real path. `@Sendable` because the
    /// read is disk I/O and must be callable off the main actor.
    nonisolated private let authFileDataProvider: @Sendable (CodexAccount) -> Data?

    /// Auth state of the *default* profile only. Kept for the default sentinel's
    /// own presentation and for callers that predate multi-account Codex; every
    /// per-account question goes through `accountAccess` instead.
    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?

    /// Last observed auth result per Codex profile, keyed by account id.
    ///
    /// Each profile points at its own `CODEX_HOME`, so a signed-in custom
    /// profile is connected even when the default sentinel is logged out or
    /// disabled. Probing is a file read plus a JSON/JWT decode, so results are
    /// cached here rather than recomputed on every render.
    @Published private(set) var accountAccess: [UUID: Bool] = [:]

    /// Last fetch failure per Codex profile, keyed by account id.
    ///
    /// `UsageDataManager` fans usage fetches out across every enabled profile
    /// concurrently, so a single shared error would end up describing whichever
    /// profile happened to finish last — a signed-out secondary profile's
    /// "Not authenticated" shown beside a healthy default, or a real default
    /// failure blanked by a later success. Keying by account keeps each fetch
    /// speaking only for itself.
    @Published private(set) var accountErrors: [UUID: ServiceError] = [:]

    /// Defaults reproduce the production singleton; tests inject a fixture
    /// auth-file provider.
    init(
        authFileDataProvider: (@Sendable () -> Data?)? = nil,
        accountAuthFileDataProvider: (@Sendable (CodexAccount) -> Data?)? = nil,
        urlSession: URLSession = ServiceSupport.session
    ) {
        self.urlSession = urlSession
        if let accountAuthFileDataProvider {
            self.authFileDataProvider = accountAuthFileDataProvider
        } else if let authFileDataProvider {
            self.authFileDataProvider = { _ in authFileDataProvider() }
        } else {
            self.authFileDataProvider = { account in
                Self.defaultAuthFileDataProvider(account: account)
            }
        }
        Task.detached(priority: .utility) { [weak self] in self?.checkAccess() }
    }

    /// Reads `CODEX_HOME/auth.json` using the same resolver as readiness,
    /// activity, and cost scans.
    nonisolated private static func defaultAuthFileDataProvider(account: CodexAccount) -> Data? {
        let path = CodexHomeDirectory.authFilePath(for: account)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    // MARK: - Auth File Access

    /// Read OAuth access token from `CODEX_HOME/auth.json`.
    /// This file is created and maintained by the Codex CLI when user logs in.
    /// `nonisolated`: disk I/O — never call this synchronously from the main actor.
    nonisolated func getAuthToken(account: CodexAccount = .defaultAccount) -> String? {
        guard let token = readAuthFile(account: account)?.tokens?.accessToken else {
            return nil
        }

        guard !OAuthTokenExpiry.isExpired(jwt: token) else {
            return nil
        }

        return token
    }

    /// Read account ID from `CODEX_HOME/auth.json`.
    /// Required for the ChatGPT-Account-Id header to get team/workspace data
    nonisolated func getAccountId(account: CodexAccount = .defaultAccount) -> String? {
        readAuthFile(account: account)?.tokens?.accountId
    }

    nonisolated private func readAuthFile(account: CodexAccount) -> CodexAuthFile? {
        guard let data = authFileDataProvider(account) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    nonisolated func hasAccess(account: CodexAccount) -> Bool {
        getAuthToken(account: account) != nil
    }

    /// `nonisolated` is load-bearing — see the lifetime note below. Do not
    /// re-isolate this to the main actor.
    nonisolated func canAccess(account: CodexAccount) async -> Bool {
        // Callers must not reach this through a stored `(CodexAccount) async ->
        // Bool` closure. Such a closure is an abstract function type, so the
        // account is passed indirectly (`@in_guaranteed`) through a
        // reabstraction thunk and this frame receives an address it does not
        // own; the copy below then retained a dead `String` and faulted in
        // `swift_retain` at `0x8`. That was the 1.8.3/1.8.31/1.8.32 crash, and
        // the fix lives at the call site — `CodexAccountSettingsRow` now binds
        // the account into a `() async -> Bool` closure so no thunk exists.
        //
        // What this function still owes its callers:
        //   1. `nonisolated` — under `SWIFT_APPROACHABLE_CONCURRENCY` that means
        //      `nonisolated(nonsending)`, so the body starts on the caller's
        //      executor with no entry hop.
        //   2. Copy into frame-owned storage first, then never read `account`
        //      again — every later use goes through `snapshot`.
        //
        // Do *not* re-verify a change here by checking instruction ordering
        // inside this function: that criterion passed on 1.8.32 and the app
        // still crashed, because the incoming address was already dead. The
        // criterion that matters is at the call site (see the note in
        // `CodexAccountSettingsRow.init`).
        let snapshot = account
        let accountID = snapshot.id
        let isDefault = snapshot.isDefault

        let isAuthenticated = await Task.detached(priority: .userInitiated) { [self] in
            hasAccess(account: snapshot)
        }.value

        await MainActor.run {
            record(isAuthenticated, accountID: accountID, isDefault: isDefault)
        }
        return isAuthenticated
    }

    /// Check and update access status
    nonisolated func checkAccess(account: CodexAccount = .defaultAccount) {
        let hasToken = getAuthToken(account: account) != nil
        ServiceSupport.applyOnMain { [weak self] in
            self?.record(hasToken, for: account)
        }
    }

    /// Single writer for auth state. The shared `hasAccess`/`subscriptionType`
    /// pair still describes the default sentinel, so a custom profile records
    /// only its own entry and never publishes over the default's.
    private func record(_ isAuthenticated: Bool, for account: CodexAccount) {
        record(isAuthenticated, accountID: account.id, isDefault: account.isDefault)
    }

    private func record(_ isAuthenticated: Bool, accountID: UUID, isDefault: Bool) {
        accountAccess[accountID] = isAuthenticated
        guard isDefault else { return }
        hasAccess = isAuthenticated
        if !isAuthenticated { subscriptionType = nil }
    }

    /// Cached auth state for one profile, falling back to the shared flag for
    /// the default sentinel until its first per-account probe lands.
    func isAuthenticated(account: CodexAccount) -> Bool {
        CodexAccountAccessProjection.isAuthenticated(
            account: account,
            accountAccess: accountAccess,
            defaultHasAccess: hasAccess
        )
    }

    /// Provider-level connection state across the supplied profiles — normally
    /// `CodexAccountStore.shared.enabledAccounts`.
    func hasAccess(in accounts: [CodexAccount]) -> Bool {
        CodexAccountAccessProjection.hasAnyAccess(
            accounts: accounts,
            accountAccess: accountAccess,
            defaultHasAccess: hasAccess
        )
    }

    /// Provider-level error across the supplied profiles, in the order given —
    /// normally `CodexAccountStore.shared.enabledAccounts`, so the default
    /// profile's failure is the one the UI reports.
    func firstError(for accounts: [CodexAccount]) -> ServiceError? {
        accounts.lazy.compactMap { self.accountErrors[$0.id] }.first
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics(account: CodexAccount = .defaultAccount) async throws -> UsageMetrics {
        // Auth-file read is disk I/O; the app target runs async bodies on the
        // main actor (default MainActor isolation), so hop off explicitly.
        let auth = await Task.detached(priority: .userInitiated) { [self] in
            (token: getAuthToken(account: account), accountId: getAccountId(account: account))
        }.value

        guard let token = auth.token else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.accountErrors[account.id] = error
                self.record(false, for: account)
            }
            throw error
        }

        // The usage endpoint is the one Codex call that wants `*/*` rather than
        // JSON; everything else about the request is the shared shape.
        let request = try makeCodexRequest(
            endpoint: usageEndpoint,
            method: "GET",
            token: token,
            accountID: auth.accountId,
            accept: "*/*"
        )

        do {
            let (data, response) = try await urlSession.data(for: request)
            try ServiceSupport.validate(response, data: data)

            let decoder = JSONDecoder()
            // Note: Codex CLI API uses Unix timestamps (Int64), not ISO8601 dates

            // Decode the actual Codex CLI usage response
            let usageResponse = try decoder.decode(CodexCliUsageResponse.self, from: data)

            await MainActor.run {
                self.accountErrors.removeValue(forKey: account.id)
                self.record(true, for: account)
                if account.isDefault {
                    self.subscriptionType = usageResponse.planType
                }
            }

            // Pure response→UsageMetrics mapping (window math, code-review limit,
            // extra-usage + reset-credit derivation) lives on the response type
            // so it's unit-testable with fixture JSON, no network.
            return usageResponse.toUsageMetrics()
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            AppLog.usage.error("Codex usage fetch failed: \(serviceError.localizedDescription)")
            await MainActor.run {
                self.accountErrors[account.id] = serviceError
                if case .notAuthenticated = serviceError {
                    self.record(false, for: account)
                }
            }
            throw serviceError
        }
    }

    // MARK: - Reset-credit action

    /// Consumes one banked Codex rate-limit reset for `account`, then immediately
    /// re-fetches usage. The POST is sent once with a fresh idempotency key; the
    /// provider owns replay protection for that key.
    func consumeResetCredit(account: CodexAccount = .defaultAccount) async throws -> CodexResetCreditConsumption {
        let auth = await Task.detached(priority: .userInitiated) { [self] in
            (token: getAuthToken(account: account), accountId: getAccountId(account: account))
        }.value

        guard let token = auth.token else {
            throw ServiceError.notAuthenticated
        }

        let credits = try await fetchResetCredits(token: token, accountID: auth.accountId)
        guard let credit = credits.credits.first(where: { $0.isAvailableCodexReset }) else {
            throw CodexResetCreditError.noAvailableCredit
        }

        let payload = ConsumeResetCreditRequest(
            creditID: credit.id,
            redeemRequestID: UUID().uuidString.lowercased()
        )
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(payload)
        } catch {
            throw CodexResetCreditError.unexpectedResponse
        }

        var request = try makeCodexRequest(
            endpoint: consumeResetCreditEndpoint,
            method: "POST",
            token: token,
            accountID: auth.accountId
        )
        request.httpBody = payloadData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response: ConsumeResetCreditResponse
        do {
            let (data, urlResponse) = try await urlSession.data(for: request)
            try ServiceSupport.validate(urlResponse, data: data)
            response = try JSONDecoder().decode(ConsumeResetCreditResponse.self, from: data)
        } catch {
            throw ServiceSupport.serviceError(from: error)
        }

        switch response.code {
        case .reset:
            break
        case .nothingToReset:
            throw CodexResetCreditError.nothingToReset
        case .noCredit:
            throw CodexResetCreditError.noAvailableCredit
        case .alreadyRedeemed:
            throw CodexResetCreditError.alreadyRedeemed
        }

        do {
            let refreshedMetrics = try await fetchUsageMetrics(account: account)
            return CodexResetCreditConsumption(
                windowsReset: response.windowsReset,
                refreshedMetrics: refreshedMetrics,
                usageRefreshErrorDescription: nil
            )
        } catch {
            // The credit was already consumed. Return success with a clear warning
            // so callers never invite a second, accidental redemption.
            return CodexResetCreditConsumption(
                windowsReset: response.windowsReset,
                refreshedMetrics: nil,
                usageRefreshErrorDescription: ServiceSupport.safeErrorMessage(for: error)
            )
        }
    }

    private func fetchResetCredits(token: String, accountID: String?) async throws -> ResetCreditsResponse {
        let request = try makeCodexRequest(
            endpoint: resetCreditsEndpoint,
            method: "GET",
            token: token,
            accountID: accountID
        )

        do {
            let (data, response) = try await urlSession.data(for: request)
            try ServiceSupport.validate(response, data: data)
            return try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        } catch {
            throw ServiceSupport.serviceError(from: error)
        }
    }

    /// Builds every ChatGPT-backed request: bearer auth, the workspace account
    /// header, and the browser identity the endpoint requires.
    ///
    /// The `ChatGPT-Account-Id` header is what makes the API return team data —
    /// without it a team account is reported as free.
    private func makeCodexRequest(
        endpoint: String,
        method: String,
        token: String,
        accountID: String?,
        accept: String = "application/json"
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        ServiceSupport.applyBrowserHeaders(to: &request, for: .chatGPT, accept: accept)
        return request
    }

    // MARK: - Response Mapping

    /// Maps a decoded Codex usage response onto the shared `UsageMetrics` shape.
    /// Thin alias over `CodexCliUsageResponse.toUsageMetrics()` — the single
    /// implementation of the window/limit derivation — kept so both fixture
    /// test suites exercise the same code path.
    static func mapUsageResponse(_ usageResponse: CodexCliUsageResponse) -> UsageMetrics {
        usageResponse.toUsageMetrics()
    }
}

// MARK: - Reset-credit models and public CLI facade

nonisolated enum CodexResetCreditEligibility {
    /// `hasResolvedAccount` guards the multi-account case: a snapshot whose
    /// `accountID` no longer matches a stored Codex profile has no `CODEX_HOME`
    /// to redeem against, so the control is hidden rather than offered with a
    /// handler that would silently no-op.
    static func isEligible(
        isBlocked: Bool,
        availableCredits: Int?,
        isAuthenticated: Bool,
        hasResolvedAccount: Bool
    ) -> Bool {
        isBlocked && (availableCredits ?? 0) > 0 && isAuthenticated && hasResolvedAccount
    }
}

/// Confirmation copy for the irreversible redemption, kept next to the service
/// so the UI dialog and the CLI's `--yes` gate describe the same spend. Both
/// strings name the account because a Codex profile is selected per
/// `CODEX_HOME` and the popover can show several cards at once.
nonisolated enum CodexResetCreditConfirmation {
    static func title(accountName: String) -> String {
        "Use a reset credit for \(accountName)?"
    }

    static func message(accountName: String, availableCredits: Int?) -> String {
        let remaining = max(availableCredits ?? 0, 0)
        let spend: String
        switch remaining {
        case 0:
            // Unknown or stale count: never render a remainder we cannot trust.
            spend = "This spends one reset credit on \(accountName)"
        case 1:
            spend = "This spends your last reset credit on \(accountName)"
        default:
            spend = "This spends 1 of \(remaining) reset credits on \(accountName)"
        }
        return "\(spend) and resets its blocked usage window. This cannot be undone."
    }
}

public struct CodexResetCreditConsumption {
    public let windowsReset: Int
    public let refreshedMetrics: UsageMetrics?
    public let usageRefreshErrorDescription: String?
}

public enum CodexResetCreditError: LocalizedError, Sendable {
    case noAvailableCredit
    case nothingToReset
    case alreadyRedeemed
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .noAvailableCredit:
            return "No Codex reset credit is available. Refresh usage and try again."
        case .nothingToReset:
            return "Codex no longer has a blocked usage window, so no reset credit was used."
        case .alreadyRedeemed:
            return "That Codex reset credit was already used. Refresh usage before trying again."
        case .unexpectedResponse:
            return "Codex returned an unexpected reset-credit response."
        }
    }
}

/// Public seam used by the bundled `meterbar reset-credit` command without
/// exposing the app's internal account-store model to the CLI target.
public enum CodexResetCreditAPI {
    public static func consume(codexHome: String? = nil) async throws -> CodexResetCreditConsumption {
        let trimmedHome = codexHome?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account: CodexAccount
        if let trimmedHome, !trimmedHome.isEmpty {
            account = CodexAccount(
                id: UUID(),
                name: "CLI reset-credit account",
                homeDirectory: (trimmedHome as NSString).standardizingPath
            )
        } else {
            account = .defaultAccount
        }
        return try await CodexCliLocalService.shared.consumeResetCredit(account: account)
    }
}

nonisolated private struct ResetCreditsResponse: Decodable {
    let credits: [ResetCredit]
}

nonisolated private struct ResetCredit: Decodable {
    let id: String
    let resetType: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
    }

    var isAvailableCodexReset: Bool {
        status == "available" && resetType == "codex_rate_limits"
    }
}

nonisolated private struct ConsumeResetCreditRequest: Encodable {
    let creditID: String
    let redeemRequestID: String

    enum CodingKeys: String, CodingKey {
        case creditID = "credit_id"
        case redeemRequestID = "redeem_request_id"
    }
}

nonisolated private struct ConsumeResetCreditResponse: Decodable {
    enum Code: String, Decodable {
        case reset
        case nothingToReset = "nothing_to_reset"
        case noCredit = "no_credit"
        case alreadyRedeemed = "already_redeemed"
    }

    let code: Code
    let windowsReset: Int

    enum CodingKeys: String, CodingKey {
        case code
        case windowsReset = "windows_reset"
    }
}

// MARK: - Response Models

/// Response structure for Codex CLI usage API from https://chatgpt.com/backend-api/wham/usage
nonisolated struct CodexCliUsageResponse: Codable {
    let planType: String
    let rateLimit: RateLimit?  // Can be null for free accounts
    let codeReviewRateLimit: CodeReviewRateLimit?
    let credits: Credits?  // Can be null for free accounts
    let spendControl: SpendControl?
    let rateLimitResetCredits: RateLimitResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
        case spendControl = "spend_control"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    /// Number of banked "rate-limit resets" the account can trigger on demand
    /// (OpenAI feature: save a quota reset and use it when you hit a limit).
    /// `nil` when the field is absent/null — i.e. the account has none banked.
    var resetCreditsAvailable: Int? {
        rateLimitResetCredits?.availableCount
    }

    /// Maps the Codex credits/spend payload onto the shared extra-usage status.
    ///
    /// Codex "extra usage" means pay-as-you-go credits/overage consumed once the plan's
    /// rate limit is hit. Because a false "Off" gives dangerous false confidence, this is
    /// safety-biased: we only report `.off` when the payload positively proves overage is
    /// disabled (the credits object is present and explicitly empty with no overage signal).
    /// Any positive signal is `.on`; an absent credits object is `.unknown`, never `.off`.
    var extraUsageStatus: ExtraUsageStatus {
        // Positive evidence that overage spending is possible / enabled.
        if let credits {
            if credits.unlimited {
                return ExtraUsageStatus(state: .on, detail: "Unlimited credits")
            }

            let balance = credits.balance ?? 0
            if credits.hasCredits || balance > 0 {
                return ExtraUsageStatus(state: .on, detail: onDetail(balance: balance))
            }

            if credits.overageLimitReached {
                return ExtraUsageStatus(state: .on, detail: "Overage in use")
            }
        }

        // A configured spend cap (or a reached cap) means overage billing is set up.
        if let limit = spendControl?.individualLimit, limit > 0 {
            return ExtraUsageStatus(state: .on, detail: "Overage cap \(ExtraUsageStatus.formatAmount(limit))")
        }
        if spendControl?.reached == true {
            return ExtraUsageStatus(state: .on, detail: "Overage in use")
        }

        // Authoritative evidence overage is disabled: credits object present and explicitly
        // empty (no balance, not unlimited, overage not in use).
        if let credits,
           !credits.unlimited,
           !credits.hasCredits,
           (credits.balance ?? 0) == 0,
           !credits.overageLimitReached {
            return ExtraUsageStatus(state: .off, detail: nil)
        }

        // No credits object at all → we cannot determine the state. Never report a false "Off".
        return ExtraUsageStatus(state: .unknown, detail: nil)
    }

    private func onDetail(balance: Double) -> String {
        var detail = "\(ExtraUsageStatus.formatAmount(balance)) in credits"
        if let limit = spendControl?.individualLimit, limit > 0 {
            detail += " · cap \(ExtraUsageStatus.formatAmount(limit))"
        }
        return detail
    }
}

// MARK: - Response → UsageMetrics mapping

extension CodexCliUsageResponse {
    /// Pure mapping from the decoded Codex usage payload to the shared
    /// `UsageMetrics`. Extracted from `fetchUsageMetrics()` so the window/limit
    /// derivation is unit-testable with fixture JSON, no network.
    ///
    /// Windows map by reported duration rather than response position: a
    /// sub-day window is the session limit and a day-or-longer window is the
    /// weekly limit. This matters when OpenAI temporarily disables the 5-hour
    /// limit and moves the only remaining weekly window into `primary_window`.
    /// Free accounts (null `rate_limit`) carry no windows, only the
    /// extra-usage/reset-credit signals.
    func toUsageMetrics() -> UsageMetrics {
        guard let rateLimit else {
            // Free accounts have a null rate_limit — no quota windows to report.
            return UsageMetrics(
                service: .codexCli,
                sessionLimit: nil,
                weeklyLimit: nil,
                codeReviewLimit: nil,
                extraUsage: extraUsageStatus,
                resetCreditsAvailable: resetCreditsAvailable
            )
        }

        let quotaWindows = [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap { $0 }
        let sessionLimit = quotaWindows.first(where: { $0.isSessionWindow })?.usageLimit
        let weeklyLimit = quotaWindows.first(where: { $0.isWeeklyWindow })?.usageLimit

        // Code review rate limit (7 days window) = code review limit
        let codeReviewLimit = codeReviewRateLimit?.primaryWindow.usageLimit

        return UsageMetrics(
            service: .codexCli,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: codeReviewLimit,
            extraUsage: extraUsageStatus,
            resetCreditsAvailable: resetCreditsAvailable
        )
    }
}

/// Optional per-account spending cap returned by the Codex usage API.
nonisolated struct SpendControl: Codable {
    let reached: Bool
    let individualLimit: Double?

    enum CodingKeys: String, CodingKey {
        case reached
        case individualLimit = "individual_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reached = (try? container.decode(Bool.self, forKey: .reached)) ?? false

        if let doubleLimit = try? container.decode(Double.self, forKey: .individualLimit) {
            individualLimit = doubleLimit
        } else if let stringLimit = try? container.decode(String.self, forKey: .individualLimit) {
            individualLimit = Double(stringLimit)
        } else {
            individualLimit = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reached, forKey: .reached)
        try container.encodeIfPresent(individualLimit, forKey: .individualLimit)
    }
}

/// Banked rate-limit resets the account can trigger on demand, from the Codex usage API.
nonisolated struct RateLimitResetCredits: Codable {
    /// How many resets are currently available to use. `nil` if absent/null.
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

nonisolated struct RateLimit: Codable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: LimitWindow
    let secondaryWindow: LimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

typealias CodeReviewRateLimit = RateLimit

nonisolated struct LimitWindow: Codable {
    private static let longWindowThresholdSeconds = 24 * 60 * 60

    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int64

    var isSessionWindow: Bool {
        limitWindowSeconds < Self.longWindowThresholdSeconds
    }

    var isWeeklyWindow: Bool {
        !isSessionWindow
    }

    var usageLimit: UsageLimit {
        UsageLimit(
            used: usedPercent,
            total: 100.0,
            resetTime: Date(timeIntervalSince1970: Double(resetAt)),
            windowSeconds: TimeInterval(limitWindowSeconds)
        )
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

nonisolated struct Credits: Codable {
    let hasCredits: Bool
    let unlimited: Bool
    let overageLimitReached: Bool
    let balance: Double?
    let approxLocalMessages: Int?
    let approxCloudMessages: Int?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case overageLimitReached = "overage_limit_reached"
        case balance
        case approxLocalMessages = "approx_local_messages"
        case approxCloudMessages = "approx_cloud_messages"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        overageLimitReached = (try? container.decode(Bool.self, forKey: .overageLimitReached)) ?? false

        if let doubleBalance = try? container.decode(Double.self, forKey: .balance) {
            balance = doubleBalance
        } else if let stringBalance = try? container.decode(String.self, forKey: .balance) {
            balance = Double(stringBalance)
        } else {
            balance = nil
        }

        approxLocalMessages = Self.decodeMessageEstimate(container, forKey: .approxLocalMessages)
        approxCloudMessages = Self.decodeMessageEstimate(container, forKey: .approxCloudMessages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasCredits, forKey: .hasCredits)
        try container.encode(unlimited, forKey: .unlimited)
        try container.encode(overageLimitReached, forKey: .overageLimitReached)
        try container.encodeIfPresent(balance, forKey: .balance)
        try container.encodeIfPresent(approxLocalMessages, forKey: .approxLocalMessages)
        try container.encodeIfPresent(approxCloudMessages, forKey: .approxCloudMessages)
    }

    private static func decodeMessageEstimate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let values = try? container.decode([Int].self, forKey: key) {
            return values.last ?? values.first
        }
        return nil
    }
}

// MARK: - Auth File Models

/// Structure of `CODEX_HOME/auth.json`.
nonisolated struct CodexAuthFile: Codable {
    let openaiApiKey: String?
    let tokens: CodexTokens?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct CodexTokens: Codable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}
