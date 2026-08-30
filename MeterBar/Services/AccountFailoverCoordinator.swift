import Foundation
import MeterBarShared
import os

nonisolated struct AccountFailoverEvent: Codable, Equatable, Sendable {
    let id: UUID
    let provider: AccountFailoverProvider
    let fromAccountID: UUID
    let fromAccountName: String
    let toAccountID: UUID
    let toAccountName: String
    let reason: AccountFailoverSwitchReason
    let timestamp: Date

    init(
        id: UUID = UUID(),
        provider: AccountFailoverProvider,
        fromAccountID: UUID,
        fromAccountName: String,
        toAccountID: UUID,
        toAccountName: String,
        reason: AccountFailoverSwitchReason,
        timestamp: Date
    ) {
        self.id = id
        self.provider = provider
        self.fromAccountID = fromAccountID
        self.fromAccountName = fromAccountName
        self.toAccountID = toAccountID
        self.toAccountName = toAccountName
        self.reason = reason
        self.timestamp = timestamp
    }
}

protocol AccountFailoverNotifying {
    func prepareForAutomaticSwitch() async -> Bool
    func notify(_ event: AccountFailoverEvent) async -> Bool
}

nonisolated struct AccountFailoverRefreshEvidence: Equatable, Sendable {
    var claudeSuccessfulAccountIDs: Set<UUID> = []
    var codexSuccessfulAccountIDs: Set<UUID> = []

    static let none = Self()

    func successfullyRefreshed(_ accountID: UUID, provider: AccountFailoverProvider) -> Bool {
        switch provider {
        case .claudeCode: claudeSuccessfulAccountIDs.contains(accountID)
        case .codexCli: codexSuccessfulAccountIDs.contains(accountID)
        }
    }
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
    private var evaluationTail: Task<Void, Never>?

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
        codexMetrics: [UUID: UsageMetrics],
        evidence: AccountFailoverRefreshEvidence = .none
    ) async {
        let previous = evaluationTail
        let work = Task { @MainActor [weak self] in
            await previous?.value
            await self?.evaluateSerialized(
                claudeMetrics: claudeMetrics,
                codexMetrics: codexMetrics,
                evidence: evidence
            )
        }
        evaluationTail = work
        await work.value
    }

    private func evaluateSerialized(
        claudeMetrics: [UUID: UsageMetrics],
        codexMetrics: [UUID: UsageMetrics],
        evidence: AccountFailoverRefreshEvidence
    ) async {
        do {
            if let pendingEvent = try await credentialSwitcher.recoverPendingTransactions() {
                await deliverAndAcknowledge(pendingEvent)
                return
            }
        } catch {
            AppLog.storage.error("Automatic account switch recovery requires attention.")
            return
        }
        await evaluateClaude(metrics: claudeMetrics, evidence: evidence)
        await evaluateCodex(metrics: codexMetrics, evidence: evidence)
    }

    private func evaluateClaude(
        metrics: [UUID: UsageMetrics],
        evidence: AccountFailoverRefreshEvidence
    ) async {
        let accounts = claudeAccounts.enabledAccounts
        await evaluate(
            provider: .claudeCode,
            accounts: accounts.map { AccountIdentity(id: $0.id, name: $0.name) },
            metrics: metrics,
            evidence: evidence
        )
    }

    private func evaluateCodex(
        metrics: [UUID: UsageMetrics],
        evidence: AccountFailoverRefreshEvidence
    ) async {
        let accounts = codexAccounts.enabledAccounts
        await evaluate(
            provider: .codexCli,
            accounts: accounts.map { AccountIdentity(id: $0.id, name: $0.name) },
            metrics: metrics,
            evidence: evidence
        )
    }

    private func evaluate(
        provider: AccountFailoverProvider,
        accounts: [AccountIdentity],
        metrics: [UUID: UsageMetrics],
        evidence: AccountFailoverRefreshEvidence
    ) async {
        guard settings.isEnabled(for: provider) else { return }
        guard credentialSwitcher.eligibility(for: provider).isEligible else {
            settings.setEnabled(false, for: provider)
            return
        }
        let orderedIDs = accounts.map(\.id)
        let activeID: UUID
        do {
            activeID = try credentialSwitcher.liveAccountID(for: provider)
        } catch {
            settings.setEnabled(false, for: provider)
            return
        }
        settings.setActiveAccountID(activeID, for: provider)
        let availability = Dictionary(uniqueKeysWithValues: orderedIDs.map {
            (
                $0,
                AccountFailoverAvailability(
                    provider: provider,
                    metrics: metrics[$0],
                    refreshedSuccessfully: evidence.successfullyRefreshed($0, provider: provider)
                )
            )
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
        case .adopt:
            return
        case let .switchAccount(from, to, reason):
            guard let fromAccount = accounts.first(where: { $0.id == from }),
                  let toAccount = accounts.first(where: { $0.id == to }) else {
                return
            }
            guard await notifier.prepareForAutomaticSwitch() else { return }
            let currentAccounts = accountIdentities(for: provider)
            guard settings.isEnabled(for: provider),
                  currentAccounts.map(\.id) == orderedIDs,
                  credentialSwitcher.eligibility(for: provider).isEligible,
                  (try? credentialSwitcher.liveAccountID(for: provider)) == from else {
                return
            }
            let event = AccountFailoverEvent(
                provider: provider,
                fromAccountID: from,
                fromAccountName: fromAccount.name,
                toAccountID: to,
                toAccountName: toAccount.name,
                reason: reason,
                timestamp: Date()
            )
            do {
                try await credentialSwitcher.switchCredentials(for: event)
                guard try credentialSwitcher.liveAccountID(for: provider) == to else {
                    throw CredentialExchangeError.recoveryRequired
                }
            } catch {
                AppLog.storage.error(
                    "Automatic account switch failed for \(provider.service.rawValue, privacy: .public)."
                )
                return
            }
            settings.setActiveAccountID(to, for: provider)
            await deliverAndAcknowledge(event)
        }
    }

    private func accountIdentities(for provider: AccountFailoverProvider) -> [AccountIdentity] {
        switch provider {
        case .claudeCode:
            claudeAccounts.enabledAccounts.map { AccountIdentity(id: $0.id, name: $0.name) }
        case .codexCli:
            codexAccounts.enabledAccounts.map { AccountIdentity(id: $0.id, name: $0.name) }
        }
    }

    private func deliverAndAcknowledge(_ event: AccountFailoverEvent) async {
        guard await notifier.notify(event) else { return }
        do {
            try credentialSwitcher.completeNotification(eventID: event.id)
        } catch {
            AppLog.storage.error("Automatic account switch notification acknowledgement will be retried.")
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

    func prepareForAutomaticSwitch() async -> Bool {
        await notificationPoster.ensureAuthorization()
    }

    func notify(_ event: AccountFailoverEvent) async -> Bool {
        await notificationPoster.post(
            identifier: "account-failover-\(event.id.uuidString.lowercased())",
            title: "\(event.provider.service.shortName) account switched",
            body: "\(event.fromAccountName) → \(event.toAccountName)"
        )
    }
}
