import Foundation
import MeterBarShared
import AppKit
import Combine

class ClaudeCodeLocalService: ObservableObject {
    // nonisolated: lets nonisolated code such as the readiness inspector
    // reference the singleton (methods keep their own isolation).
    nonisolated static let shared = ClaudeCodeLocalService()

    /// Authenticated Claude Code usage endpoint — the same data Claude Code's
    /// own `/usage` screen reads. `nonisolated static` so the side-effect-free
    /// fetch (used by the background session-wake quota gate) can reach it
    /// without touching main-actor state.
    nonisolated static let defaultUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    private let usageEndpoint = ClaudeCodeLocalService.defaultUsageEndpoint

    private let keychainService = "Claude Code-credentials"
    private let cliUsageService = ClaudeCodeCLIUsageService.shared

    private let urlSession = ServiceSupport.session

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var authState: ClaudeCodeAuthState = .unavailable

    private init() {
        // Defer keychain/filesystem I/O off the init thread, like the other
        // local services (this previously ran synchronously in init).
        Task.detached(priority: .utility) { [weak self] in self?.checkAccess() }
    }

    // MARK: - Keychain Access

    /// Get OAuth token from Claude Code's keychain storage.
    /// `nonisolated`: a keychain read can raise a blocking approval dialog —
    /// never call synchronously from the main actor.
    nonisolated func getOAuthToken() -> String? {
        guard let credentials = getCredentials() else {
            return nil
        }

        guard !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            ServiceSupport.applyOnMain {
                self.subscriptionType = credentials.claudeAiOauth.subscriptionType
                self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
                self.hasAccess = false
            }
            return nil
        }

        ServiceSupport.applyOnMain {
            self.subscriptionType = credentials.claudeAiOauth.subscriptionType
            self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
            self.hasAccess = true
        }

        return credentials.claudeAiOauth.accessToken
    }

    nonisolated private func getCredentials() -> ClaudeCodeCredentials? {
        guard let data = credentialsData() else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
    }

    /// The raw "Claude Code-credentials" keychain blob, or nil if absent/unreadable.
    ///
    /// Exposed for provider-readiness diagnostics, which pass the bytes to the
    /// pure readiness core (it reads only the expiry claim — never surfaces the
    /// token). Reading the raw blob here keeps the keychain query in one place.
    nonisolated func credentialsData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return data
    }

    /// Check and update access status.
    /// `nonisolated`: file stats + (with the OAuth fallback) a keychain read —
    /// call from a detached task.
    nonisolated func checkAccess() {
        let newHasAccess: Bool
        let newAuthState: ClaudeCodeAuthState
        let clearsSubscription: Bool

        if cliUsageService.isAvailable() {
            newHasAccess = true
            newAuthState = .cliAvailable
            clearsSubscription = false
        } else if isOAuthFallbackEnabled, getOAuthToken() != nil {
            newHasAccess = true
            newAuthState = .connected(.oauth)
            clearsSubscription = false
        } else {
            newHasAccess = false
            newAuthState = .unavailable
            clearsSubscription = !isOAuthFallbackEnabled || getCredentials() == nil
        }

        ServiceSupport.applyOnMain { [weak self] in
            guard let self else { return }
            self.hasAccess = newHasAccess
            self.authState = newAuthState
            if clearsSubscription {
                self.subscriptionType = nil
                self.rateLimitTier = nil
            }
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics(account: ClaudeCodeAccount = .defaultAccount) async throws -> UsageMetrics {
        // Primary source: the authenticated `/api/oauth/usage` endpoint — the
        // same data Claude Code's own `/usage` screen reads. `claude /usage` no
        // longer renders in a headless (non-TTY) spawn (it prints a session cost
        // summary instead), so the CLI parser is now a fallback. Only the
        // unscoped default account can safely use the global Keychain token;
        // accounts with an explicit `CLAUDE_CONFIG_DIR` go straight to the CLI.
        if Self.prefersOAuth(account: account, oauthEnabled: isOAuthFallbackEnabled) {
            // `nil` ⇒ no usable Keychain token; fall back to the CLI. A thrown
            // error means a token was in hand but the request/decode failed —
            // surface it rather than retry the headless-broken CLI.
            if let metrics = try await fetchUsageViaOAuth() {
                return metrics
            }
        }

        return try await fetchUsageViaCLI(account: account)
    }

    /// Fetches usage from the OAuth `/api/oauth/usage` endpoint for the default
    /// account and updates the app's `@Published` auth/error state. Returns
    /// `nil` when there is no usable Keychain token (missing or expired) so the
    /// caller can fall back to the CLI. The actual request/decode is delegated
    /// to the pure `fetchOAuthMetrics(token:)`; this wrapper adds only the UI
    /// side effects.
    private func fetchUsageViaOAuth() async throws -> UsageMetrics? {
        // Keychain read — off the main actor (it can raise a blocking approval
        // dialog, and the app target runs async bodies on the main actor).
        // `getOAuthToken()` also refreshes `subscriptionType`/`hasAccess`.
        let token = await Task.detached(priority: .userInitiated) { [self] in
            getOAuthToken()
        }.value

        guard let token else { return nil }

        do {
            let metrics = try await Self.fetchOAuthMetrics(token: token, session: urlSession)
            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                self.authState = .connected(.oauth)
            }
            return metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            await MainActor.run {
                self.lastError = serviceError
                if case .notAuthenticated = serviceError {
                    self.hasAccess = false
                    self.authState = .needsLogin
                } else {
                    self.authState = .error(serviceError.localizedDescription)
                }
            }
            throw serviceError
        }
    }

    /// Pure, side-effect-free fetch of Claude Code usage from `/api/oauth/usage`.
    ///
    /// Reads no `@Published` state and performs no `MainActor` mutation, so it
    /// is safe to call from a nonisolated background context — e.g. the
    /// session-wake quota gate, which must not couple UI state into background
    /// polls. The caller supplies the bearer token; this builds the request,
    /// validates the response, decodes it, and maps it onto `UsageMetrics`,
    /// mapping any failure onto `ServiceError` (fail fast — never returns a
    /// partial reading).
    nonisolated static func fetchOAuthMetrics(
        token: String,
        endpoint: String = defaultUsageEndpoint,
        session: URLSession = ServiceSupport.session
    ) async throws -> UsageMetrics {
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await session.data(for: request)
            try ServiceSupport.validate(response, data: data)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usageResponse = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)
            return metrics(from: usageResponse)
        } catch {
            throw ServiceSupport.serviceError(from: error)
        }
    }

    /// Reads a non-expired Claude Code OAuth access token from the Keychain
    /// *without* mutating any `@Published` state. Returns `nil` when the
    /// credential is missing or expired. The UI-facing `getOAuthToken()`
    /// additionally refreshes published subscription/access state; background
    /// callers (the wake quota gate) must not, so they use this instead.
    nonisolated func nonMutatingOAuthToken() -> String? {
        guard let credentials = getCredentials(),
              !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            return nil
        }
        return credentials.claudeAiOauth.accessToken
    }

    /// Side-effect-free OAuth usage fetch for background callers (the
    /// session-wake quota gate). Reads a non-expired Keychain token off the main
    /// actor and, when present, fetches `/api/oauth/usage` — mutating NO
    /// `@Published`/`MainActor` state. Returns `nil` when there is no usable
    /// token so the caller can fall back to the CLI; throws when a token was in
    /// hand but the request/decode failed (fail closed).
    nonisolated static func oauthMetricsWithoutSideEffects() async throws -> UsageMetrics? {
        let token = await Task.detached(priority: .userInitiated) {
            shared.nonMutatingOAuthToken()
        }.value
        guard let token else { return nil }
        return try await fetchOAuthMetrics(token: token)
    }

    /// Fallback source: shells out to `claude /usage` and parses the terminal
    /// output. Used for custom accounts and when no OAuth token is available.
    private func fetchUsageViaCLI(account: ClaudeCodeAccount) async throws -> UsageMetrics {
        do {
            let metrics = try await cliUsageService.fetchUsageMetrics(account: account)
            await MainActor.run {
                // This observable service describes the default Claude
                // connection. A logged-out secondary profile must not overwrite
                // the provider-wide state after the default profile refreshed.
                if Self.publishesSharedConnectionState(for: account) {
                    self.lastError = nil
                    self.hasAccess = true
                    self.authState = .connected(.cli)
                }
            }
            // The CLI output does not expose the "extra usage" toggle. Only read
            // Claude's OAuth keychain item when OAuth is enabled; ad-hoc local
            // installs otherwise trigger a keychain approval prompt on every
            // rebuilt binary.
            let extraUsage = await fetchExtraUsageStatus(account: account)
            return metrics.withExtraUsage(extraUsage)
        } catch {
            let serviceError = serviceError(from: error)
            await MainActor.run {
                if Self.publishesSharedConnectionState(for: account) {
                    self.lastError = serviceError
                    self.hasAccess = false
                    self.authState = authState(from: error)
                }
            }
            throw serviceError
        }
    }

    /// OAuth (`/api/oauth/usage`) is the primary Claude Code usage source and is
    /// enabled by default. Users opt out — e.g. unsigned dev builds that
    /// re-prompt for Keychain access on every rebuild — by setting the flag
    /// false. Single source of truth for the three call sites that read it.
    nonisolated static func isOAuthUsageEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: StorageKeys.claudeCodeOAuthFallback) as? Bool) ?? true
    }

    /// OAuth is preferred only for the unscoped default account. When
    /// `CLAUDE_CONFIG_DIR` explicitly selects a profile, the global Keychain
    /// item may belong to a different Claude identity; use that profile's CLI
    /// instead so account metrics cannot cross-contaminate.
    nonisolated static func prefersOAuth(
        account: ClaudeCodeAccount,
        oauthEnabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard account.isDefault, oauthEnabled else { return false }
        if let accountConfigDirectory = account.configDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accountConfigDirectory.isEmpty {
            return false
        }
        let configDirectory = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configDirectory?.isEmpty != false
    }

    /// The singleton's published connection/error state backs the provider-wide
    /// Settings overview, so only the default profile is allowed to mutate it.
    /// Custom-profile failures are represented by their own no-data cards.
    nonisolated static func publishesSharedConnectionState(for account: ClaudeCodeAccount) -> Bool {
        account.isDefault
    }

    /// Maps an `/api/oauth/usage` response onto the shared `UsageMetrics`.
    /// Session = 5-hour window, weekly = 7-day (all models), code-review =
    /// the provider-named model weekly window when the server emits one.
    nonisolated static func metrics(from response: ClaudeCodeUsageResponse) -> UsageMetrics {
        let sessionLimit = UsageLimit(
            used: response.fiveHour.utilization,
            total: 100.0,
            resetTime: response.fiveHour.resetsAt,
            windowSeconds: 5 * 60 * 60
        )

        let weeklyLimit = UsageLimit(
            used: response.sevenDay.utilization,
            total: 100.0,
            resetTime: response.sevenDay.resetsAt,
            windowSeconds: 7 * 24 * 60 * 60
        )

        let modelWindow: (window: UsageWindow, label: String)?
        if let fable = response.sevenDayFable {
            modelWindow = (fable, "Fable")
        } else if let sonnet = response.sevenDaySonnet {
            modelWindow = (sonnet, "Sonnet")
        } else {
            modelWindow = nil
        }

        let codeReviewLimit = modelWindow.map {
            UsageLimit(
                used: $0.window.utilization,
                total: 100.0,
                resetTime: $0.window.resetsAt,
                windowSeconds: 7 * 24 * 60 * 60
            )
        }

        return UsageMetrics(
            service: .claudeCode,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: codeReviewLimit,
            modelLimitLabel: modelWindow?.label,
            extraUsage: response.extraUsageStatus
        )
    }

    /// Best-effort fetch of the Claude "extra usage" on/off state from the OAuth usage endpoint.
    ///
    /// Only the unscoped default account is supported, since its OAuth token lives in the Keychain.
    /// Reads credentials without mutating published state and never throws — any missing token,
    /// expired token, network failure, or decode failure resolves to `.unknown`.
    private func fetchExtraUsageStatus(account: ClaudeCodeAccount) async -> ExtraUsageStatus {
        guard Self.prefersOAuth(account: account, oauthEnabled: isOAuthFallbackEnabled) else { return .unknown }
        // Keychain read — off the main actor, same as the fallback-token path.
        let storedCredentials = await Task.detached(priority: .utility) { [self] in
            getCredentials()
        }.value
        guard let credentials = storedCredentials,
              !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            return .unknown
        }

        guard let url = URL(string: usageEndpoint) else { return .unknown }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return .unknown
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usageResponse = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)
            return usageResponse.extraUsageStatus
        } catch {
            return .unknown
        }
    }

    nonisolated private var isOAuthFallbackEnabled: Bool {
        Self.isOAuthUsageEnabled()
    }

    private func serviceError(from error: Error) -> ServiceError {
        if let serviceError = error as? ServiceError {
            return serviceError
        }

        if let cliError = error as? ClaudeCodeCLIUsageError {
            switch cliError {
            case .cliNotFound:
                return .notAuthenticated
            case .parsingFailed:
                return .parsingError
            case .timedOut, .launchFailed, .commandFailed:
                return .apiError(cliError.localizedDescription)
            }
        }

        return .apiError(error.localizedDescription)
    }

    private func authState(from error: Error) -> ClaudeCodeAuthState {
        guard let cliError = error as? ClaudeCodeCLIUsageError else {
            return .error(error.localizedDescription)
        }

        switch cliError {
        case .cliNotFound:
            return .unavailable
        case let .commandFailed(message):
            let lowercased = message.lowercased()
            if lowercased.contains("login") || lowercased.contains("auth") || lowercased.contains("unauthorized") {
                return .needsLogin
            }
            return .error(cliError.localizedDescription)
        case .timedOut, .launchFailed, .parsingFailed:
            return .error(cliError.localizedDescription)
        }
    }
}

enum ClaudeCodeUsageSource: String {
    case cli = "Claude CLI"
    case oauth = "OAuth"
}

enum ClaudeCodeAuthState: Equatable {
    case unavailable
    case cliAvailable
    case connected(ClaudeCodeUsageSource)
    case needsLogin
    case error(String)

    var statusText: String {
        switch self {
        case .unavailable:
            return "Not Connected"
        case .cliAvailable:
            return "Ready (Claude CLI)"
        case let .connected(source):
            return "Connected (\(source.rawValue))"
        case .needsLogin:
            return "Login Required"
        case .error:
            return "Needs Attention"
        }
    }

    var guidanceText: String {
        switch self {
        case .unavailable:
            return "Install Claude Code and run 'claude login'."
        case .cliAvailable:
            return "Ready. MeterBar reads usage from your Claude Code login; refresh to update."
        case .connected(.cli):
            return "Using Claude CLI usage output."
        case .connected(.oauth):
            return "Using Claude Code's OAuth usage endpoint."
        case .needsLogin:
            return "Run 'claude login' again."
        case let .error(message):
            return message
        }
    }
}

// MARK: - Response Models

nonisolated struct ClaudeCodeCredentials: Codable {
    let claudeAiOauth: ClaudeAiOAuth
}

nonisolated struct ClaudeAiOAuth: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?
}

nonisolated struct ClaudeCodeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?
    let sevenDayFable: UsageWindow?
    let extraUsage: ClaudeExtraUsage?
    let spend: ClaudeSpend?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayFable = "seven_day_fable"
        case extraUsage = "extra_usage"
        case spend
    }

    /// Maps the Claude `extra_usage`/`spend` payload onto the shared extra-usage status.
    ///
    /// Claude Code "extra usage" lets Max accounts keep working past their plan limits
    /// by billing overage to their payment method. The authoritative flag is
    /// `extra_usage.is_enabled`; `spend.enabled` is used as a fallback.
    var extraUsageStatus: ExtraUsageStatus {
        if let extraUsage {
            guard extraUsage.isEnabled else {
                return ExtraUsageStatus(state: .off, detail: nil)
            }
            return ExtraUsageStatus(state: .on, detail: enabledDetail)
        }

        // `spend.enabled` only positively confirms ON. A false value is not authoritative for
        // the extra-usage toggle (only `extra_usage.is_enabled` is), so treat it as unknown
        // rather than risk a false "Off".
        if spend?.enabled == true {
            return ExtraUsageStatus(state: .on, detail: enabledDetail)
        }

        return .unknown
    }

    private var enabledDetail: String? {
        var parts: [String] = []
        if let spend, let used = spend.used?.amount {
            parts.append("\(ExtraUsageStatus.formatAmount(used, currency: spend.used?.currency)) used")
        }
        if let limit = extraUsage?.monthlyLimit, limit > 0 {
            parts.append("cap \(ExtraUsageStatus.formatAmount(limit, currency: extraUsage?.currency))/mo")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Claude `extra_usage` object from `/api/oauth/usage`.
nonisolated struct ClaudeExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
        case disabledReason = "disabled_reason"
    }
}

/// Claude `spend` object from `/api/oauth/usage`.
nonisolated struct ClaudeSpend: Codable {
    let used: ClaudeMoney?
    let limit: ClaudeMoney?
    let percent: Double?
    let enabled: Bool?
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case used
        case limit
        case percent
        case enabled
        case disabledReason = "disabled_reason"
    }
}

/// Minor-unit money amount (e.g. `amount_minor: 500, exponent: 2` → $5.00).
nonisolated struct ClaudeMoney: Codable {
    let amountMinor: Int?
    let currency: String?
    let exponent: Int?

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
    }

    /// Decoded major-unit amount, or nil when no minor amount is present.
    var amount: Double? {
        guard let amountMinor else { return nil }
        let exp = exponent ?? 2
        return Double(amountMinor) / pow(10, Double(exp))
    }
}

nonisolated struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
