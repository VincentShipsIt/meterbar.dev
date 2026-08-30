import Foundation
import MeterBarShared

/// Builds the coarse quota payload from provider-issued account identities.
/// Local profile UUIDs are intentionally absent: they are installation-local
/// and would make two Macs double-count the same subscription.
enum ICloudQuotaSnapshotSource {
    private struct CodexInput: Sendable {
        let account: CodexAccount
        let metrics: UsageMetrics
    }

    private struct ClaudeInput: Sendable {
        let account: ClaudeCodeAccount
        let metrics: UsageMetrics
    }

    @MainActor
    static func live() async -> [ICloudQuotaSnapshot] {
        let dataManager = UsageDataManager.shared
        let codexInputs = CodexAccountStore.shared.enabledAccounts.compactMap { account -> CodexInput? in
            let fallback = account.isDefault && dataManager.codexAccountMetrics.isEmpty
                ? dataManager.metrics[.codexCli]
                : nil
            guard let metrics = dataManager.codexAccountMetrics[account.id] ?? fallback else { return nil }
            return CodexInput(account: account, metrics: metrics)
        }
        let claudeInputs = ClaudeCodeAccountStore.shared.accounts
            .filter(\.isEnabled)
            .compactMap { account -> ClaudeInput? in
                let fallback = account.isDefault ? dataManager.metrics[.claudeCode] : nil
                guard let metrics = dataManager.claudeCodeAccountMetrics[account.id] ?? fallback else { return nil }
                return ClaudeInput(account: account, metrics: metrics)
            }
        let cursorMetrics = dataManager.metrics[.cursor]
        let codexService = CodexCliLocalService.shared
        let claudeService = ClaudeCodeLocalService.shared
        let cursorService = CursorLocalService.shared

        return await Task.detached(priority: .utility) {
            var snapshots = codexInputs.compactMap { input in
                ICloudQuotaSnapshot(
                    metrics: input.metrics,
                    externalAccountIdentity: codexService.getAccountId(account: input.account)
                )
            }
            snapshots += claudeInputs.compactMap { input in
                ICloudQuotaSnapshot(
                    metrics: input.metrics,
                    externalAccountIdentity: claudeService.externalAccountIdentity(for: input.account)
                )
            }
            if let cursorMetrics,
               let snapshot = ICloudQuotaSnapshot(
                   metrics: cursorMetrics,
                   externalAccountIdentity: cursorService.externalAccountIdentity()
               ) {
                snapshots.append(snapshot)
            }
            return deduplicated(snapshots)
        }.value
    }

    nonisolated private static func deduplicated(
        _ snapshots: [ICloudQuotaSnapshot]
    ) -> [ICloudQuotaSnapshot] {
        var latest: [String: ICloudQuotaSnapshot] = [:]
        for snapshot in snapshots {
            let key = "\(snapshot.provider.rawValue):\(snapshot.accountIdentity)"
            if latest[key].map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                latest[key] = snapshot
            }
        }
        return latest.values.sorted {
            if $0.provider.sortOrder != $1.provider.sortOrder {
                return $0.provider.sortOrder < $1.provider.sortOrder
            }
            return $0.accountIdentity < $1.accountIdentity
        }
    }
}
