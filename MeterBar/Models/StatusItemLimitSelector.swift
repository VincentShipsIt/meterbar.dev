import Foundation
import MeterBarShared

/// One account/provider quota competing for the menu bar percentage slot.
struct StatusLimitCandidate: Equatable {
    /// Stable identity across refreshes (e.g. "claude:<uuid>", "codex", "cursor")
    /// so the sticky selection can recognize the previously shown account.
    let key: String
    /// Human-readable label for the status item tooltip.
    let displayName: String
    let limit: UsageLimit
    /// Most recent on-disk activity for the account, nil when undetectable.
    let lastActivity: Date?
}

/// Picks which quota the menu bar title shows.
///
/// The menu bar used to pin the tightest quota across *all* enabled accounts,
/// so a drained account that wasn't in use dominated the number forever. This
/// selector instead follows the accounts with recent on-disk activity, and is
/// sticky: when several accounts are active at once (one Claude + one Codex),
/// the shown account only changes when it goes idle or another active account
/// becomes clearly tighter — never ping-ponging on small fluctuations.
enum StatusItemLimitSelector {
    /// Activity newer than this counts as "in use".
    static let activityWindow: TimeInterval = 30 * 60
    /// Keep the previously shown account while it is within this many
    /// %-left points of the tightest candidate.
    static let hysteresisPoints = 5

    static func select(
        candidates: [StatusLimitCandidate],
        previousKey: String?,
        now: Date = Date(),
        activityWindow: TimeInterval = Self.activityWindow,
        hysteresisPoints: Int = Self.hysteresisPoints
    ) -> StatusLimitCandidate? {
        guard !candidates.isEmpty else { return nil }

        let active = candidates.filter { candidate in
            guard let lastActivity = candidate.lastActivity else { return false }
            return now.timeIntervalSince(lastActivity) <= activityWindow
        }

        // No detectable activity anywhere: fall back to the old behavior and
        // let every enabled account compete.
        let pool = active.isEmpty ? candidates : active

        guard let tightest = pool.min(by: { lhs, rhs in
            let lhsLeft = QuotaMath.percentLeft(for: lhs.limit)
            let rhsLeft = QuotaMath.percentLeft(for: rhs.limit)
            // Tie-break on key so equal quotas resolve deterministically.
            return (lhsLeft, lhs.key) < (rhsLeft, rhs.key)
        }) else { return nil }

        if let previousKey,
           let previous = pool.first(where: { $0.key == previousKey }),
           QuotaMath.percentLeft(for: previous.limit)
               <= QuotaMath.percentLeft(for: tightest.limit) + hysteresisPoints {
            return previous
        }

        return tightest
    }
}
