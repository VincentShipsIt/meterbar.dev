import Foundation
import AppKit
import Combine

class ClaudeCodeLocalService: ObservableObject {
    static let shared = ClaudeCodeLocalService()

    // Working endpoint (discovered via testing)
    private let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"

    private let baseURL = "https://api.anthropic.com"
    private let keychainService = "Claude Code-credentials"
    private let cliUsageService = ClaudeCodeCLIUsageService.shared
    private let oauthFallbackUserDefaultsKey = "ClaudeCodeEnableOAuthFallback"

    // URLSession with timeout configuration
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    @Published private(set) var hasAccess: Bool = false
    @Published private(set) var subscriptionType: String?
    @Published private(set) var rateLimitTier: String?
    @Published private(set) var lastError: ServiceError?
    @Published private(set) var authState: ClaudeCodeAuthState = .unavailable

    private init() {
        // Check if we have Claude Code credentials on init
        checkAccess()
    }

    // MARK: - Keychain Access

    /// Get OAuth token from Claude Code's keychain storage
    func getOAuthToken() -> String? {
        guard let credentials = getCredentials() else {
            return nil
        }

        guard !OAuthTokenExpiry.isExpired(unixTimestamp: credentials.claudeAiOauth.expiresAt) else {
            DispatchQueue.main.async {
                self.subscriptionType = credentials.claudeAiOauth.subscriptionType
                self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
                self.hasAccess = false
            }
            return nil
        }

        DispatchQueue.main.async {
            self.subscriptionType = credentials.claudeAiOauth.subscriptionType
            self.rateLimitTier = credentials.claudeAiOauth.rateLimitTier
            self.hasAccess = true
        }

        return credentials.claudeAiOauth.accessToken
    }

    private func getCredentials() -> ClaudeCodeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: jsonData) else {
            return nil
        }

        return credentials
    }

    /// Check and update access status
    func checkAccess() {
        if cliUsageService.isAvailable() {
            hasAccess = true
            authState = .cliAvailable
        } else if isOAuthFallbackEnabled, let _ = getOAuthToken() {
            hasAccess = true
            authState = .connected(.legacyOAuth)
        } else {
            hasAccess = false
            authState = .unavailable
            if !isOAuthFallbackEnabled || getCredentials() == nil {
                subscriptionType = nil
                rateLimitTier = nil
            }
        }
    }

    // MARK: - Usage Fetching

    func fetchUsageMetrics(account: ClaudeCodeAccount = .defaultAccount) async throws -> UsageMetrics {
        do {
            let metrics = try await cliUsageService.fetchUsageMetrics(account: account)
            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                if account.isDefault || self.authState == .unavailable {
                    self.authState = .connected(.cli)
                }
            }
            // The CLI usage output does not expose the "extra usage" toggle, so query the
            // OAuth usage endpoint separately for it. Best-effort: failures degrade to .unknown.
            let extraUsage = await fetchExtraUsageStatus(account: account)
            return metrics.withExtraUsage(extraUsage)
        } catch {
            if !account.isDefault || !isOAuthFallbackEnabled {
                let serviceError = serviceError(from: error)
                await MainActor.run {
                    self.lastError = serviceError
                    if account.isDefault {
                        self.hasAccess = false
                        self.authState = authState(from: error)
                    }
                }
                throw serviceError
            }
        }

        guard let token = getOAuthToken() else {
            let error = ServiceError.notAuthenticated
            await MainActor.run {
                self.lastError = error
                self.hasAccess = false
                self.authState = .needsLogin
            }
            throw error
        }

        guard let url = URL(string: usageEndpoint) else {
            throw ServiceError.apiError("Invalid usage endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30.0

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.apiError("Invalid response type")
            }

            if httpResponse.statusCode == 401 {
                await MainActor.run {
                    self.hasAccess = false
                    self.lastError = ServiceError.notAuthenticated
                    self.authState = .needsLogin
                }
                throw ServiceError.notAuthenticated
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw ServiceError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usageResponse = try decoder.decode(ClaudeCodeUsageResponse.self, from: data)

            await MainActor.run {
                self.lastError = nil
                self.hasAccess = true
                self.authState = .connected(.legacyOAuth)
            }

            // Session limit = 5-hour window
            let sessionLimit = UsageLimit(
                used: usageResponse.fiveHour.utilization,
                total: 100.0,
                resetTime: usageResponse.fiveHour.resetsAt,
                windowSeconds: 5 * 60 * 60
            )

            // Weekly limit = 7-day window (all models)
            let weeklyLimit = UsageLimit(
                used: usageResponse.sevenDay.utilization,
                total: 100.0,
                resetTime: usageResponse.sevenDay.resetsAt,
                windowSeconds: 7 * 24 * 60 * 60
            )

            // Sonnet-only weekly limit (if available)
            var sonnetLimit: UsageLimit? = nil
            if let sonnet = usageResponse.sevenDaySonnet {
                sonnetLimit = UsageLimit(
                    used: sonnet.utilization,
                    total: 100.0,
                    resetTime: sonnet.resetsAt,
                    windowSeconds: 7 * 24 * 60 * 60
                )
            }

            return UsageMetrics(
                service: .claudeCode,
                sessionLimit: sessionLimit,
                weeklyLimit: weeklyLimit,
                codeReviewLimit: sonnetLimit,
                extraUsage: usageResponse.extraUsageStatus
            )
        } catch let urlError as URLError {
            let errorMessage: String
            switch urlError.code {
            case .notConnectedToInternet:
                errorMessage = "No internet connection"
            case .cannotFindHost, .dnsLookupFailed:
                errorMessage = "DNS lookup failed"
            case .timedOut:
                errorMessage = "Request timed out"
            default:
                errorMessage = urlError.localizedDescription
            }
            let error = ServiceError.apiError(errorMessage)
            await MainActor.run {
                self.lastError = error
                self.authState = .error(errorMessage)
            }
            throw error
        } catch let error as ServiceError {
            throw error
        } catch {
            let serviceError = ServiceError.parsingError
            await MainActor.run {
                self.lastError = serviceError
                self.authState = .error(serviceError.localizedDescription)
            }
            throw serviceError
        }
    }

    /// Best-effort fetch of the Claude "extra usage" on/off state from the OAuth usage endpoint.
    ///
    /// Only the default account is supported, since its OAuth token lives in the Keychain.
    /// Reads credentials without mutating published state and never throws — any missing token,
    /// expired token, network failure, or decode failure resolves to `.unknown`.
    private func fetchExtraUsageStatus(account: ClaudeCodeAccount) async -> ExtraUsageStatus {
        guard account.isDefault else { return .unknown }
        guard let credentials = getCredentials(),
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

    private var isOAuthFallbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: oauthFallbackUserDefaultsKey)
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
    case legacyOAuth = "Legacy OAuth"
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
            return "Using Claude CLI usage output; refresh to update."
        case .connected(.cli):
            return "Using Claude CLI usage output."
        case .connected(.legacyOAuth):
            return "Using legacy OAuth fallback."
        case .needsLogin:
            return "Run 'claude login' again."
        case let .error(message):
            return message
        }
    }
}

// MARK: - Response Models

struct ClaudeCodeCredentials: Codable {
    let claudeAiOauth: ClaudeAiOAuth

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}

struct ClaudeAiOAuth: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct ClaudeCodeUsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ClaudeExtraUsage?
    let spend: ClaudeSpend?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
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
struct ClaudeExtraUsage: Codable {
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
struct ClaudeSpend: Codable {
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
struct ClaudeMoney: Codable {
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

struct UsageWindow: Codable {
    let utilization: Double
    let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
