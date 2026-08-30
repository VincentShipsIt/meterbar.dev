import Foundation
import MeterBarShared
import os

nonisolated struct AccountFailoverEvent: Sendable {
    let provider: AccountFailoverProvider
    let fromAccountID: UUID
    let fromAccountName: String
    let toAccountID: UUID
    let toAccountName: String
    let reason: AccountFailoverSwitchReason
    let timestamp: Date
}

protocol AccountFailoverNotifying {
    func notify(_ event: AccountFailoverEvent) async
}

/// Applies pure decisions only after an existing refresh has committed fresh
/// account snapshots. No timer or provider request originates here.
@MainActor
final class AccountFailoverCoordinator {
    static let shared = AccountFailoverCoordinator()

    private let settings: AccountFailoverSettingsStore
    private let claudeAccounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore
    private let credentialSwitcher: AccountCredentialSwitching
    private let notifier: AccountFailoverNotifying

    init(
        settings: AccountFailoverSettingsStore? = nil,
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        credentialSwitcher: AccountCredentialSwitching? = nil,
        notifier: AccountFailoverNotifying? = nil
    ) {
        self.settings = settings ?? .shared
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.credentialSwitcher = credentialSwitcher ?? LiveAccountCredentialSwitcher.shared
        self.notifier = notifier ?? LiveAccountFailoverNotifier.shared
    }

    func evaluate(
        claudeMetrics: [UUID: UsageMetrics],
        codexMetrics: [UUID: UsageMetrics]
    ) async {
        do {
            try await credentialSwitcher.recoverPendingTransactions()
        } catch {
            AppLog.storage.error("Automatic account switch recovery requires attention.")
            return
        }
        await evaluateClaude(metrics: claudeMetrics)
        await evaluateCodex(metrics: codexMetrics)
    }

    private func evaluateClaude(metrics: [UUID: UsageMetrics]) async {
        let accounts = claudeAccounts.enabledAccounts
        await evaluate(
            provider: .claudeCode,
            accounts: accounts.map { AccountIdentity(id: $0.id, name: $0.name) },
            metrics: metrics
        )
    }

    private func evaluateCodex(metrics: [UUID: UsageMetrics]) async {
        let accounts = codexAccounts.enabledAccounts
        await evaluate(
            provider: .codexCli,
            accounts: accounts.map { AccountIdentity(id: $0.id, name: $0.name) },
            metrics: metrics
        )
    }

    private func evaluate(
        provider: AccountFailoverProvider,
        accounts: [AccountIdentity],
        metrics: [UUID: UsageMetrics]
    ) async {
        guard credentialSwitcher.eligibility(for: provider).isEligible else {
            settings.setEnabled(false, for: provider)
            return
        }
        let orderedIDs = accounts.map(\.id)
        settings.reconcileAccounts(orderedIDs, for: provider)
        let activeID = settings.activeAccountID(for: provider, orderedAccountIDs: orderedIDs)
        let availability = Dictionary(uniqueKeysWithValues: orderedIDs.map {
            ($0, AccountFailoverAvailability(metrics: metrics[$0]))
        })
        let decision = AccountFailoverDecisionEngine.decide(
            AccountFailoverDecisionInput(
                isEnabled: settings.isEnabled(for: provider),
                orderedAccountIDs: orderedIDs,
                activeAccountID: activeID,
                availability: availability
            )
        )

        switch decision {
        case .stay:
            return
        case let .adopt(accountID, _):
            settings.setActiveAccountID(accountID, for: provider)
        case let .switchAccount(from, to, reason):
            guard let fromAccount = accounts.first(where: { $0.id == from }),
                  let toAccount = accounts.first(where: { $0.id == to }) else {
                return
            }
            do {
                try await credentialSwitcher.switchCredentials(provider: provider, from: from, to: to)
            } catch {
                AppLog.storage.error(
                    "Automatic account switch failed for \(provider.service.rawValue, privacy: .public)."
                )
                return
            }
            settings.setActiveAccountID(to, for: provider)
            await notifier.notify(
                AccountFailoverEvent(
                    provider: provider,
                    fromAccountID: from,
                    fromAccountName: fromAccount.name,
                    toAccountID: to,
                    toAccountName: toAccount.name,
                    reason: reason,
                    timestamp: Date()
                )
            )
        }
    }

    private struct AccountIdentity {
        let id: UUID
        let name: String
    }
}

@MainActor
final class LiveAccountFailoverNotifier: AccountFailoverNotifying {
    static let shared = LiveAccountFailoverNotifier()

    private let notificationPoster: UserNotificationPosting

    init(notificationPoster: UserNotificationPosting? = nil) {
        self.notificationPoster = notificationPoster ?? LiveUserNotificationPoster.shared
    }

    func notify(_ event: AccountFailoverEvent) async {
        await notificationPoster.post(
            identifier: "account-failover-\(event.provider.rawValue)-\(event.timestamp.timeIntervalSince1970)",
            title: "\(event.provider.service.shortName) account switched",
            body: "\(event.fromAccountName) → \(event.toAccountName)"
        )
    }
}
