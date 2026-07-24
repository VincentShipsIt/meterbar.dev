import Foundation
import MeterBarShared

/// Default provider for Codex quota: the same Codex usage service the app and
/// menu bar use, scoped to the account's CODEX_HOME. Conforms to the unified
/// `WakeQuotaProviding` with `Account == CodexAccount`; the generic
/// `WakeQuotaAuthority<CodexAccount>` provides the fail-closed gate.
nonisolated struct LiveCodexWakeQuotaProvider: WakeQuotaProviding {
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics {
        try await CodexCliLocalService.shared.fetchUsageMetrics(account: account)
    }
}
