import Foundation
import MeterBarShared

/// Source of *fresh* Codex quota, scoped to a selected `CodexAccount`
/// (CODEX_HOME). Mirrors `WakeQuotaProviding` but over the Codex account type;
/// cached UI metrics are never accepted as launch authority.
nonisolated protocol CodexWakeQuotaProviding: Sendable {
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics
}

/// Default provider: the same Codex usage service the app and menu bar use,
/// scoped to the account's CODEX_HOME.
nonisolated struct LiveCodexWakeQuotaProvider: CodexWakeQuotaProviding {
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics {
        try await CodexCliLocalService.shared.fetchUsageMetrics(account: account)
    }
}

/// Resolves a fresh Codex quota decision, failing closed on any error,
/// staleness, or ambiguity — the same contract as the Claude authority. The
/// classification itself is provider-agnostic (`WakeQuota.classify` reads only
/// the shared `UsageMetrics`), so Codex's primary (5h) window maps onto the
/// session limit and its secondary (weekly) window onto the weekly limit with
/// no change to the gate.
nonisolated struct CodexWakeQuotaAuthority: Sendable {
    private let provider: CodexWakeQuotaProviding
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    init(
        provider: CodexWakeQuotaProviding = LiveCodexWakeQuotaProvider(),
        maxAge: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.maxAge = maxAge
        self.now = now
    }

    func freshQuota(account: CodexAccount) async -> WakeQuota {
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
