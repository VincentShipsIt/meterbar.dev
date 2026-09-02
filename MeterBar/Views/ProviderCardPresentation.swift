import MeterBarShared
import SwiftUI

/// Pure display rules for `ProviderStatusCard`.
///
/// These were private computed properties on the card, so the only way to check
/// "does an exhausted provider still offer a detail chevron?" was to host a view
/// and inspect the render. Extracting them keeps the card declarative and makes
/// each rule directly assertable.
enum ProviderCardPresentation {
    /// The auth notice outranks the band. A card built from a stale cache still
    /// has genuinely healthy percentages, so the band alone would paint it green
    /// and hide the fact that the account is logged out — the exact failure this
    /// overlay exists to prevent. Login/attention borrow the warning colour;
    /// stale and not-connected go subdued rather than shouting.
    static func statusColor(for snapshot: ProviderSnapshot) -> Color {
        switch snapshot.authNotice {
        case .loginRequired, .attention:
            return MeterBarTheme.warning
        case .stale, .notConnected:
            return .secondary
        case .none:
            return snapshot.band?.color ?? .secondary
        }
    }

    static func statusText(for snapshot: ProviderSnapshot) -> String {
        if let notice = snapshot.authNotice { return notice.shortLabel }
        return snapshot.band?.shortLabel ?? "Offline"
    }

    /// How long a login-required card may keep showing its cached gauges before
    /// they stop being useful context and start being noise. Two hours is past
    /// any session window the cache could still be describing.
    static let loginCollapseStaleInterval: TimeInterval = 2 * 60 * 60

    /// A logged-out account whose cache has aged past
    /// ``loginCollapseStaleInterval`` collapses to a one-line "Login required"
    /// row: the bars underneath describe a session that ended hours ago, and the
    /// only action that changes anything is logging back in. A *fresh* cache
    /// stays expanded — those numbers were true minutes ago and still orient the
    /// user. Cards with no cache at all belong to the offline row instead.
    static func collapsesToLoginRow(snapshot: ProviderSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.authNotice == .loginRequired, let updatedAt = snapshot.updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > loginCollapseStaleInterval
    }

    /// Cards without usage data and exhausted cards are terminal summaries. A
    /// login/waiting card has no quota detail to reveal, while an exhausted card
    /// already shows its only actionable reset information inline. A collapsed
    /// stale-login row is terminal too: its detail panel would present hours-old
    /// gauges as if they were live.
    /// "Live" marks the account automatic failover is currently routing the
    /// CLI to. The coordinator records the signed-in credential on every
    /// refresh even while failover is off, so the chip must also check that
    /// failover is enabled — otherwise it just restates which credential the
    /// CLI happens to hold, which is noise (and confusing next to "Out").
    static func showsLiveAccount(
        for snapshot: ProviderSnapshot,
        failoverSettings: AccountFailoverSettingsStore
    ) -> Bool {
        guard snapshot.isAccountCard,
              let accountID = snapshot.accountID,
              let provider = AccountFailoverProvider(service: snapshot.service),
              failoverSettings.isEnabled(for: provider)
        else { return false }
        return failoverSettings.activeAccountIDs[provider] == accountID
    }

    static func allowsDetailNavigation(
        hasSelectionHandler: Bool,
        snapshot: ProviderSnapshot,
        now: Date = Date()
    ) -> Bool {
        hasSelectionHandler
            && snapshot.hasMetrics
            && !snapshot.hasExhaustedLimit
            && !collapsesToLoginRow(snapshot: snapshot, now: now)
    }

    /// Reset credits are banked usage-window resets on Codex CLI and Grok.
    /// The eligibility rule already hides the action once the provider reports
    /// no credits left, but the count it reads is only as fresh as the last
    /// poll: a redemption whose follow-up refetch failed leaves the snapshot
    /// still claiming the spent credit is there. `hasPendingConsumption` covers
    /// exactly that window — see `CodexResetCreditConsumptionStore`, which drops
    /// the record as soon as newer metrics arrive.
    ///
    /// It is deliberately not a permanent latch. An account can bank several
    /// credits, and once refreshed numbers land the count is authoritative, so
    /// the action must come back for the next one.
    static func showsResetCreditAction(
        snapshot: ProviderSnapshot,
        hasPendingConsumption: Bool,
        isAuthenticated: Bool,
        hasResolvedAccount: Bool
    ) -> Bool {
        guard snapshot.service == .codexCli || snapshot.service == .grok, !hasPendingConsumption else {
            return false
        }
        return CodexResetCreditEligibility.isEligible(
            isBlocked: snapshot.hasExhaustedLimit,
            availableCredits: snapshot.resetCreditsAvailable,
            isAuthenticated: isAuthenticated,
            hasResolvedAccount: hasResolvedAccount
        )
    }
}
