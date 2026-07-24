import Foundation
import MeterBarShared

/// Source of *fresh* account-scoped quota. Cached UI metrics are never passed
/// here — the authority always pulls a live reading so a launch decision can
/// never rest on stale numbers. Generic over the provider's account type so one
/// authority serves every provider (Claude, Codex, ...).
nonisolated protocol WakeQuotaProviding<Account>: Sendable {
    associatedtype Account
    func fetchMetrics(account: Account) async throws -> UsageMetrics
}

/// Default provider. For the default account it prefers the authenticated
/// `/api/oauth/usage` endpoint — the same source the usage card adopted in
/// PR #175 — because `claude /usage` no longer renders in a headless (non-TTY)
/// spawn and its parse fails. It falls back to the `claude /usage` CLI for
/// custom accounts (which have no Keychain token), a missing/expired token, or
/// an OAuth opt-out. The OAuth path is side-effect-free: unlike the usage
/// card's `ClaudeCodeLocalService.fetchUsageMetrics`, it never mutates
/// `@Published` UI state, so background wake polls stay decoupled from the UI.
nonisolated struct LiveWakeQuotaProvider: WakeQuotaProviding {
    /// Fetches usage via OAuth without UI side effects; `nil` ⇒ no usable
    /// Keychain token, so fall back to the CLI. A throw ⇒ a token was in hand
    /// but the request failed — surface it (fail closed) rather than retry the
    /// headless-broken CLI.
    private let oauthMetrics: @Sendable () async throws -> UsageMetrics?
    /// Fallback: shells out to `claude /usage` for the given account.
    private let cliMetrics: @Sendable (ClaudeCodeAccount) async throws -> UsageMetrics
    /// Whether the OAuth source is enabled (user opt-out honored).
    private let oauthEnabled: @Sendable () -> Bool

    init(
        oauthMetrics: @escaping @Sendable () async throws -> UsageMetrics? = {
            try await ClaudeCodeLocalService.oauthMetricsWithoutSideEffects()
        },
        cliMetrics: @escaping @Sendable (ClaudeCodeAccount) async throws -> UsageMetrics = { account in
            try await ClaudeCodeCLIUsageService.shared.fetchUsageMetrics(account: account)
        },
        oauthEnabled: @escaping @Sendable () -> Bool = {
            ClaudeCodeLocalService.isOAuthUsageEnabled()
        }
    ) {
        self.oauthMetrics = oauthMetrics
        self.cliMetrics = cliMetrics
        self.oauthEnabled = oauthEnabled
    }

    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
        if ClaudeCodeLocalService.prefersOAuth(account: account, oauthEnabled: oauthEnabled()) {
            // `nil` ⇒ no usable token: fall through to the CLI. A throw
            // propagates so the authority fails closed to `.unknown`.
            if let metrics = try await oauthMetrics() {
                return metrics
            }
        }
        return try await cliMetrics(account)
    }
}

/// Resolves a fresh quota decision for the selected account, failing closed on
/// any error, staleness, or ambiguity. Generic over the account type.
nonisolated struct WakeQuotaAuthority<Account>: Sendable {
    private let provider: any WakeQuotaProviding<Account>
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    init(
        provider: any WakeQuotaProviding<Account>,
        maxAge: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.maxAge = maxAge
        self.now = now
    }

    /// Fetch and classify fresh quota for `account`.
    /// - A thrown fetch ⇒ `.unknown` (fail closed).
    /// - Metrics older than `maxAge` ⇒ `.unknown` (never treat cache as truth).
    func freshQuota(account: Account) async -> WakeQuota {
        let metrics: UsageMetrics
        do {
            metrics = try await provider.fetchMetrics(account: account)
        } catch {
            return .unknown(reason: "quota fetch failed: \(error.localizedDescription)")
        }
        if now().timeIntervalSince(metrics.lastUpdated) > maxAge {
            return .unknown(reason: "quota reading is stale")
        }
        return WakeQuota.classify(metrics)
    }
}
