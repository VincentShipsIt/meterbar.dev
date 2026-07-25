import MeterBarShared
import SwiftUI

/// Pure display rules for `ProviderStatusCard`.
///
/// These were private computed properties on the card, so the only way to check
/// "does an exhausted provider still offer a detail chevron?" was to host a view
/// and inspect the render. Extracting them keeps the card declarative and makes
/// each rule directly assertable.
enum ProviderCardPresentation {
    static func statusColor(for snapshot: ProviderSnapshot) -> Color {
        snapshot.band?.color ?? .secondary
    }

    static func statusText(for snapshot: ProviderSnapshot) -> String {
        snapshot.band?.shortLabel ?? "Offline"
    }

    /// Cards without usage data and exhausted cards are terminal summaries. A
    /// login/waiting card has no quota detail to reveal, while an exhausted card
    /// already shows its only actionable reset information inline.
    static func allowsDetailNavigation(hasSelectionHandler: Bool, snapshot: ProviderSnapshot) -> Bool {
        hasSelectionHandler && snapshot.hasMetrics && !snapshot.hasExhaustedLimit
    }

    /// Reset credits are a Codex CLI concept. `didConsumeResetCredit` suppresses
    /// the action for the rest of the card's lifetime: the snapshot's credit
    /// count is only refreshed on the next poll, so without it a spent credit
    /// stays offered and invites a double redemption.
    static func showsResetCreditAction(
        snapshot: ProviderSnapshot,
        didConsumeResetCredit: Bool,
        isAuthenticated: Bool,
        hasResolvedAccount: Bool
    ) -> Bool {
        guard snapshot.service == .codexCli, !didConsumeResetCredit else { return false }
        return CodexResetCreditEligibility.isEligible(
            isBlocked: snapshot.hasExhaustedLimit,
            availableCredits: snapshot.resetCreditsAvailable,
            isAuthenticated: isAuthenticated,
            hasResolvedAccount: hasResolvedAccount
        )
    }

    static func fableActivityAccessibilityLabel(
        _ activity: FableSessionCardActivity,
        status: FableSessionCardActivity.Status
    ) -> String {
        switch status {
        case .active:
            return "Fable 5, active"
        case .recent:
            guard let lastObservedAt = activity.session?.lastObservedAt else {
                return "Fable 5, recent activity"
            }
            return "Fable 5, last seen \(lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
        case .noActivity:
            return "Fable 5, no activity"
        }
    }
}
