import Foundation
import MeterBarShared
import AppKit
import Combine

nonisolated private enum ClaudeStoredCredentials {
    case value(ClaudeCodeCredentials)
    case missing
    case unavailable
}

nonisolated private enum ClaudeCredentialReadBarrier: Error {
    case unavailable
}

class ClaudeCodeLocalService: ObservableObject {
    // nonisolated: lets nonisolated code such as the readiness inspector
    // reference the singleton (methods keep their own isolation).
    nonisolated static let shared = ClaudeCodeLocalService()

    /// Authenticated Claude Code usage endpoint — the same data Claude Code's
    /// own `/usage` screen reads. `nonisolated static` so the side-effect-free
    /// fetch (used by the background session-wake quota gate) can reach it
    /// without touching main-actor state.
    nonisolated static let defaultUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    /// Timeout for the metrics fetch — the user-visible reading, worth waiting on.
    nonisolated static let usageRequestTimeout: TimeInterval = 30.0

    /// Timeout for the extra-usage probe. Deliberately shorter than
    /// `usageRequestTimeout`: it is best-effort, resolves to `.unknown` on any
    /// failure, and must not stall a refresh behind a hung connection.
    nonisolated static let extraUsageRequestTimeout: TimeInterval = 15.0

    private let usageEndpoint = ClaudeCodeLocalService.defaultUsageEndpoint

    private let credentialStore = ClaudeCredentialStore.shared
    private let cliUsageService = ClaudeCodeCLIUsageService.shared
    private let tokenRefresher = ClaudeTokenRefresher.shared

    private let urlSession = ServiceSupport.session

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var authState: ClaudeCodeAuthState = .unavailable

    /// Last fetch failure per Claude profile, keyed by account id.
    ///
    /// `lastError` / `authState` describe only the default profile (they back
    /// the provider-wide Settings overview). Custom-account failures must not
    /// overwrite that, and a healthy default must not hide a broken custom
    /// profile. Read account-scoped errors through `firstError(for:)`.
    @Published private(set) var accountErrors: [UUID: ServiceError] = [:]

    /// The last observed auth/connection state *per account*. `authState` above
    /// describes only the default profile, because it backs the provider-wide
    /// Settings overview; a logged-out secondary profile used to compute its
    /// state and then discard it, leaving its card to render a green band off a
    /// stale cache. Every fetch leg records here, gated on nothing.
    @Published private(set) var accountAuthStates: [UUID: ClaudeCodeAuthState] = [:]

    private init() {
        // Defer keychain/filesystem I/O off the init thread, like the other
        // local services (this previously ran synchronously in init).
        Task.detached(priority: .utility) { [weak self] in self?.checkAccess() }
    }

    // MARK: - Keychain Access

    /// Get the OAuth token for `account` from Claude Code's credential storage.
    /// `nonisolated`: a Keychain read can block. The default is no-UI;
    /// interactive mode is reserved for explicit user refresh actions.
    nonisolated func getOAuthToken(
        for account: ClaudeCodeAccount = .defaultAccount,
        mode: ClaudeKeychainAccessMode = .background
    ) -> String? {
        guard case let .valid(token) = oauthCredentialAccessUpdatingSharedState(
            for: account,
            mode: mode
        ) else {
            return nil
        }
        return token
    }

    nonisolated private func getCredentials(
        for account: ClaudeCodeAccount = .defaultAccount,
        mode: ClaudeKeychainAccessMode = .background
    ) -> ClaudeCodeCredentials? {
        guard case let .value(credentials) = storedCredentials(for: account, mode: mode) else {
            return nil
        }
        return credentials
    }

    nonisolated private func storedCredentials(
        for account: ClaudeCodeAccount,
        mode: ClaudeKeychainAccessMode
    ) -> ClaudeStoredCredentials {
        switch credentialStore.credentialsDataResult(for: account, mode: mode) {
        case let .value(data):
            guard let credentials = try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: data) else {
                return .missing
            }
            return .value(credentials)
        case .notFound:
            return .missing
        case .interactionRequired, .denied, .failure:
            return .unavailable
        }
    }

    nonisolated func oauthCredentialAccess(
        for account: ClaudeCodeAccount = .defaultAccount,
        mode: ClaudeKeychainAccessMode = .background
    ) -> ClaudeOAuthCredentialAccess {
        switch storedCredentials(for: account, mode: mode) {
        case let .value(credentials):
            return Self.oauthCredentialAccess(from: credentials)
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    nonisolated static func oauthCredentialAccess(
        from credentials: ClaudeCodeCredentials?
    ) -> ClaudeOAuthCredentialAccess {
        guard let credentials else {
            return .missing
        }
        guard !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            return .expired
        }
        return .valid(token: credentials.claudeAiOauth.accessToken)
    }

    nonisolated private func oauthCredentialAccessUpdatingSharedState(
        for account: ClaudeCodeAccount,
        mode: ClaudeKeychainAccessMode = .background
    ) -> ClaudeOAuthCredentialAccess {
        let stored = storedCredentials(for: account, mode: mode)
        guard case let .value(credentials) = stored else {
            if case .unavailable = stored {
                return .unavailable
            }
            return .missing
        }
        let access = Self.oauthCredentialAccess(from: credentials)
        let hasValidToken: Bool
        if case .valid = access {
            hasValidToken = true
        } else {
            hasValidToken = false
        }
        ServiceSupport.applyOnMain {
            self.subscriptionType = credentials.claudeAiOauth.subscriptionType
            self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
            self.hasAccess = hasValidToken
        }
        return access
    }

    /// The raw Claude Code credential blob for `account`, or nil if
    /// absent/unreadable.
    ///
    /// Exposed for provider-readiness diagnostics, which pass the bytes to the
    /// pure readiness core (it reads only the expiry claim — never surfaces the
    /// token). `ClaudeCredentialStore` owns the per-profile candidate walk.
    nonisolated func credentialsData(
        for account: ClaudeCodeAccount = .defaultAccount,
        mode: ClaudeKeychainAccessMode = .background
    ) -> Data? {
        credentialStore.credentialsData(for: account, mode: mode)
    }

    /// Check and update access status.
    /// `nonisolated`: file stats + (with the OAuth fallback) a no-UI Keychain
    /// read — call from a detached task.
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

    func firstError(for accounts: [ClaudeCodeAccount]) -> ServiceError? {
        accounts.lazy.compactMap { self.accountErrors[$0.id] }.first
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics(account: ClaudeCodeAccount = .defaultAccount) async throws -> UsageMetrics {
        try await fetchUsageMetrics(account: account, trigger: .background)
    }

    func fetchUsageMetrics(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) async throws -> UsageMetrics {
        // Primary source: the authenticated `/api/oauth/usage` endpoint — the
        // same data Claude Code's own `/usage` screen reads. `claude /usage` no
        // longer renders in a headless (non-TTY) spawn (it prints a session cost
        // summary instead), so the CLI parser is now a fallback. Every account
        // may attempt OAuth: `ClaudeCredentialStore` resolves the credential
        // Claude Code wrote for *that* profile, and a scoped profile can never
        // reach the unscoped item, so identities cannot cross-contaminate.
        var oauthUnauthenticated = false
        if isOAuthFallbackEnabled {
            // `nil` ⇒ no credential for this profile; fall back to the CLI. A
            // thrown error means either delegated refresh could not verify a
            // rotated token or an OAuth request/decode failed — surface it
            // rather than retry the headless-broken CLI.
            do {
                if let metrics = try await fetchUsageViaOAuth(account: account, trigger: trigger) {
                    return metrics
                }
            } catch is ClaudeCredentialReadBarrier {
                // The credential may exist behind an ACL that background
                // access cannot satisfy. Preserve the CLI fallback without
                // converting its failure into a false "Login required".
                return try await fetchUsageViaCLI(account: account, isLoggedOut: false)
            }
            // No credential for this profile. Remember that, so a downstream
            // CLI parse failure reports "Login required" instead of a vague
            // "Needs attention" — a logged-out profile is by far the common
            // cause, and `claude /usage` prints a cost summary rather than the
            // usage screen when the profile is not logged in.
            oauthUnauthenticated = true
        }

        return try await fetchUsageViaCLI(account: account, isLoggedOut: oauthUnauthenticated)
    }

    /// Fetches usage from the OAuth `/api/oauth/usage` endpoint for `account`
    /// and, for the default profile only, updates the app's `@Published`
    /// auth/error state. A missing credential retains the CLI fallback. An
    /// expired credential first delegates refresh to the Claude CLI, accepts
    /// success only when its metadata fingerprint changes, and re-reads once.
    private func fetchUsageViaOAuth(
        account: ClaudeCodeAccount,
        trigger: ClaudeTokenRefreshTrigger
    ) async throws -> UsageMetrics? {
        // Keychain read — off the main actor (it can raise a blocking approval
        // dialog, and the app target runs async bodies on the main actor).
        // The state-updating read also refreshes `subscriptionType`/`hasAccess`.
        let publishesSharedState = Self.publishesSharedConnectionState(for: account)
        let keychainMode = ClaudeKeychainAccessMode(trigger: trigger)
        let initialAccess = await Task.detached(priority: .userInitiated) { [self] in
            publishesSharedState
                ? oauthCredentialAccessUpdatingSharedState(for: account, mode: keychainMode)
                : oauthCredentialAccess(for: account, mode: keychainMode)
        }.value

        let tokenRefresher = self.tokenRefresher
        let resolvedAccess = await ClaudeOAuthAccessCoordinator.resolve(
            initialAccess: initialAccess,
            account: account,
            trigger: trigger,
            refresh: { account, trigger in
                await tokenRefresher.refresh(account: account, trigger: trigger)
            },
            reread: {
                // An explicit refresh gets one interactive candidate walk. The
                // post-CLI reread is no-UI so a single action cannot prompt
                // twice for the same account.
                await Task.detached(priority: .userInitiated) { [self] in
                    oauthCredentialAccess(for: account, mode: .background)
                }.value
            }
        )

        let resolvedToken: String
        switch resolvedAccess {
        case let .token(token):
            resolvedToken = token
        case .missing:
            return nil
        case .unavailable:
            throw ClaudeCredentialReadBarrier.unavailable
        case .refreshFailed:
            publishNeedsLogin(account: account, publishesSharedState: publishesSharedState)
            throw ServiceError.notAuthenticated
        }

        do {
            let metrics = try await Self.fetchOAuthMetrics(token: resolvedToken, session: urlSession)
            await MainActor.run {
                // Same rule as the CLI path: this observable service describes
                // the default Claude connection, so a secondary profile must not
                // overwrite provider-wide state.
                if publishesSharedState {
                    self.lastError = nil
                    self.hasAccess = true
                    self.authState = .connected(.oauth)
                }
                self.accountErrors.removeValue(forKey: account.id)
                self.accountAuthStates[account.id] = .connected(.oauth)
            }
            return metrics
        } catch {
            let serviceError = ServiceSupport.serviceError(from: error)
            let state: ClaudeCodeAuthState
            if case .notAuthenticated = serviceError {
                state = .needsLogin
            } else {
                state = .error(serviceError.localizedDescription)
            }
            await MainActor.run {
                self.accountErrors[account.id] = serviceError
                self.accountAuthStates[account.id] = state
                guard publishesSharedState else { return }
                self.lastError = serviceError
                if case .needsLogin = state {
                    self.hasAccess = false
                }
                self.authState = state
            }
            throw serviceError
        }
    }

    private func publishNeedsLogin(
        account: ClaudeCodeAccount,
        publishesSharedState: Bool
    ) {
        accountErrors[account.id] = .notAuthenticated
        accountAuthStates[account.id] = .needsLogin
        guard publishesSharedState else { return }
        lastError = .notAuthenticated
        hasAccess = false
        authState = .needsLogin
    }

    /// Builds an authenticated GET against the OAuth usage endpoint.
    ///
    /// Both callers — the metrics fetch and the extra-usage probe — hit the same
    /// URL with the same four headers and differed only in `timeoutInterval`, so
    /// the header set had to be kept in sync by hand. `timeout` stays a required
    /// parameter precisely because that difference is intentional: see
    /// `usageRequestTimeout` and `extraUsageRequestTimeout`.
    ///
    /// - Returns: `nil` when `endpoint` is empty or unparseable, which each
    ///   caller maps onto its own failure mode.
    nonisolated static func usageRequest(
        token: String,
        endpoint: String = defaultUsageEndpoint,
        timeout: TimeInterval
    ) -> URLRequest? {
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = timeout
        return request
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
        guard let request = Self.usageRequest(
            token: token,
            endpoint: endpoint,
            timeout: Self.usageRequestTimeout
        ) else {
            throw ServiceError.invalidURL
        }

        do {
            // Network + decode must not run as main-actor jobs: same
            // `NSURLSession.data(for:)` null-receiver hazard as Cursor /
            // OpenRouter (#480) and Codex when default actor isolation is
            // MainActor. 1.8.39 crashed on launch in this hop — the keychain
            // read was already detached, the usage GET was not.
            let capturedSession = session
            return try await Task.detached(priority: .userInitiated) {
                let (data, response) = try await capturedSession.data(for: request)
                try ServiceSupport.validate(response, data: data)
                let usageResponse = try decodeUsageResponse(from: data)
                return metrics(from: usageResponse)
            }.value
        } catch {
            throw ServiceSupport.serviceError(from: error)
        }
    }

    /// The OAuth metrics fetch and best-effort extra-usage probe decode the
    /// same response contract with the same date strategy.
    nonisolated static func decodeUsageResponse(from data: Data) throws -> ClaudeCodeUsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClaudeCodeUsageResponse.self, from: data)
    }

    /// Reads a non-expired Claude Code OAuth access token for `account`
    /// *without* mutating any `@Published` state. Returns `nil` when the
    /// credential is missing or expired. The UI-facing `getOAuthToken(for:)`
    /// additionally refreshes published subscription/access state; background
    /// callers (the wake quota gate) and secondary profiles must not, so they
    /// use this instead.
    nonisolated func nonMutatingOAuthToken(
        for account: ClaudeCodeAccount = .defaultAccount
    ) -> String? {
        guard let credentials = getCredentials(for: account),
              !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            return nil
        }
        return credentials.claudeAiOauth.accessToken
    }

    /// Side-effect-free OAuth usage fetch for background callers (the
    /// session-wake quota gate). Reads a non-expired token for `account` off the
    /// main actor and, when present, fetches `/api/oauth/usage` — mutating NO
    /// `@Published`/`MainActor` state. Returns `nil` when there is no usable
    /// token so the caller can fall back to the CLI; throws when a token was in
    /// hand but the request/decode failed (fail closed).
    nonisolated static func oauthMetricsWithoutSideEffects(
        account: ClaudeCodeAccount = .defaultAccount
    ) async throws -> UsageMetrics? {
        let token = await Task.detached(priority: .userInitiated) {
            shared.nonMutatingOAuthToken(for: account)
        }.value
        guard let token else { return nil }
        return try await fetchOAuthMetrics(token: token)
    }

    /// Fallback source: shells out to `claude /usage` and parses the terminal
    /// output. Used for custom accounts and when no OAuth token is available.
    ///
    /// - Parameter isLoggedOut: the OAuth step already established that this
    ///   profile has no usable credential. A CLI failure then means "logged
    ///   out", not "something broke", and must be reported as such.
    private func fetchUsageViaCLI(
        account: ClaudeCodeAccount,
        isLoggedOut: Bool = false
    ) async throws -> UsageMetrics {
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
                // A CLI-only login is still a login, so this succeeds even when
                // the OAuth step above found no credential.
                self.accountErrors.removeValue(forKey: account.id)
                self.accountAuthStates[account.id] = .connected(.cli)
            }
            // The CLI output does not expose the "extra usage" toggle. Only read
            // Claude's OAuth keychain item when OAuth is enabled; ad-hoc local
            // installs otherwise trigger a keychain approval prompt on every
            // rebuilt binary.
            let extraUsage = await fetchExtraUsageStatus(account: account)
            return metrics.withExtraUsage(extraUsage)
        } catch {
            let serviceError = serviceError(from: error)
            // Without the OAuth hint, a logged-out profile surfaces as a parse
            // failure ("Needs Attention") because `claude /usage` prints a cost
            // summary instead of the usage screen. That reads as a bug in
            // MeterBar rather than as the actionable "run claude login".
            let state = isLoggedOut ? ClaudeCodeAuthState.needsLogin : authState(from: error)
            await MainActor.run {
                self.accountErrors[account.id] = serviceError
                self.accountAuthStates[account.id] = state
                if Self.publishesSharedConnectionState(for: account) {
                    self.lastError = serviceError
                    self.hasAccess = false
                    self.authState = state
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
    /// Resolves that profile's own credential, so a scoped account reports its own
    /// toggle rather than the unscoped identity's. Reads credentials without mutating
    /// published state and never throws — any missing token, expired token, network
    /// failure, or decode failure resolves to `.unknown`.
    private func fetchExtraUsageStatus(account: ClaudeCodeAccount) async -> ExtraUsageStatus {
        guard isOAuthFallbackEnabled else { return .unknown }
        // Keychain read — off the main actor, same as the fallback-token path.
        let storedCredentials = await Task.detached(priority: .utility) { [self] in
            getCredentials(for: account)
        }.value
        guard let credentials = storedCredentials,
              !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            return .unknown
        }

        guard let request = Self.usageRequest(
            token: credentials.claudeAiOauth.accessToken,
            endpoint: usageEndpoint,
            timeout: Self.extraUsageRequestTimeout
        ) else {
            return .unknown
        }

        do {
            let session = urlSession
            return try await Task.detached(priority: .utility) {
                let (data, response) = try await session.data(for: request)
                try ServiceSupport.validate(response, data: data)
                let usageResponse = try Self.decodeUsageResponse(from: data)
                return usageResponse.extraUsageStatus
            }.value
        } catch {
            return .unknown
        }
    }

    nonisolated private var isOAuthFallbackEnabled: Bool {
        Self.isOAuthUsageEnabled()
    }

    private func serviceError(from error: Error) -> ServiceError {
        ClaudeCodeCLIFailureMapping.serviceError(from: error)
    }

    private func authState(from error: Error) -> ClaudeCodeAuthState {
        ClaudeCodeCLIFailureMapping.authState(from: error)
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
    /// The last refresh failed but an earlier reading survives in cache. The
    /// numbers on screen are real, just old — distinct from `.error`, which has
    /// nothing to show, and from `.needsLogin`, which says why refreshing will
    /// keep failing until the user acts.
    case stale(since: Date)

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
        case .stale:
            return "Stale"
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
        case let .stale(since):
            return "Showing the last reading from \(UsageFormat.relative(since)); the latest refresh failed."
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
