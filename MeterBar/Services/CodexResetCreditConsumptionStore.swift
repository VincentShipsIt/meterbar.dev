import Combine
import Foundation

// MARK: - CodexResetCreditConsumptionStore

/// Tracks Codex reset credits that were spent but are not yet reflected in any
/// snapshot, keyed by account.
///
/// `consumeResetCredit` can succeed and still fail to refetch usage, in which
/// case the card is left quoting the pre-spend credit count. Offering the action
/// against that count invites a second, real redemption, so the spend has to be
/// remembered somewhere until fresher numbers arrive.
///
/// It used to be remembered in the card's own `@State`, which was not durable
/// enough: the dashboard deals cards into columns by array position, so any
/// change to the snapshot list — another account finishing a poll, a provider
/// gaining or losing metrics — could move a card, tear down its state, and
/// re-offer the credit it had just spent. Keying the record by account id puts
/// it out of reach of view churn.
///
/// The record is deliberately not a permanent latch. Each spend is stamped with
/// the moment it completed, and any snapshot whose metrics were fetched after
/// that instant supersedes it: those numbers already account for the spend, so
/// the eligibility rule can be trusted again and an account with a second banked
/// credit gets its button back. Superseded records are left in place rather than
/// pruned — reads happen from `body`, which must not mutate — and there is one
/// entry per Codex account at worst. Nothing is persisted; a relaunch refetches
/// usage before any card can offer the action.
final class CodexResetCreditConsumptionStore: ObservableObject {
    // MARK: Internal

    static let shared = CodexResetCreditConsumptionStore()

    /// Completion instant of the last unconfirmed redemption per account.
    @Published private(set) var consumedAt: [UUID: Date] = [:]

    /// Records a redemption whose result is not yet visible in any snapshot.
    func markConsumed(accountID: UUID, at date: Date = Date()) {
        consumedAt[accountID] = date
    }

    /// Drops the record because authoritative post-spend numbers arrived — the
    /// count on screen is now the real remaining balance.
    func clear(accountID: UUID) {
        consumedAt.removeValue(forKey: accountID)
    }

    /// Whether `snapshotUpdatedAt` may still be quoting a credit this account
    /// has already spent. A pure read: it is called from view bodies.
    ///
    /// An undated snapshot has no cached metrics at all, so it can never be the
    /// newer evidence that clears a record.
    func hasPendingConsumption(accountID: UUID?, snapshotUpdatedAt: Date?) -> Bool {
        guard let accountID, let consumedAt = consumedAt[accountID] else { return false }
        guard let snapshotUpdatedAt else { return true }
        return snapshotUpdatedAt <= consumedAt
    }

    func clearAll() {
        consumedAt.removeAll()
    }
}
