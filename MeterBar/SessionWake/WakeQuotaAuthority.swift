import Foundation
import MeterBarShared

/// Source of *fresh* account-scoped quota. Cached UI metrics are never passed
/// here — the authority always pulls a live reading so a launch decision can
/// never rest on stale numbers.
protocol WakeQuotaProviding: Sendable {
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics
}

/// Default provider: the same `claude /usage` service the app and CLI already
/// use, scoped to the selected account's `CLAUDE_CONFIG_DIR`.
struct LiveWakeQuotaProvider: WakeQuotaProviding {
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
        try await ClaudeCodeCLIUsageService.shared.fetchUsageMetrics(account: account)
    }
}

/// Resolves a fresh quota decision for the selected account, failing closed on
/// any error, staleness, or ambiguity.
struct WakeQuotaAuthority: Sendable {
    private let provider: WakeQuotaProviding
    /// Metrics older than this are not accepted as execution authority even if
    /// a fetch returned them.
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    init(
        provider: WakeQuotaProviding = LiveWakeQuotaProvider(),
        maxAge: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.maxAge = maxAge
        self.now = now
    }

    /// Fetch and classify fresh quota for `account`.
    ///
    /// - A thrown fetch (missing OAuth, CLI error) ⇒ `.unknown` (fail closed).
    /// - Metrics older than `maxAge` ⇒ `.unknown` (never treat cache as truth).
    func freshQuota(account: ClaudeCodeAccount) async -> WakeQuota {
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
