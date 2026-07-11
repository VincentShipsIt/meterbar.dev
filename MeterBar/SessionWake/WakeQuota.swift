import Foundation
import MeterBarShared

/// The account-scoped quota decision that gates every launch.
///
/// Only `.available` authorizes running a session. Everything else — a known
/// block or any doubt at all — refuses to launch. This is the fail-closed
/// contract: missing, stale, failed, or ambiguous quota is `.unknown`, never
/// silently treated as available.
nonisolated enum WakeQuota: Equatable, Sendable {
    /// A hard window is open and fresh enough to authorize one launch.
    case available
    /// A hard window is exhausted; `until` is its reset instant when known.
    case blocked(until: Date?, reason: WakeBlockReason)
    /// Quota could not be established as authority (missing/stale/failed).
    case unknown(reason: String)

    /// The single predicate the coordinator is allowed to launch on.
    var allowsLaunch: Bool {
        if case .available = self { return true }
        return false
    }

    /// Classify fresh metrics into a quota decision.
    ///
    /// Gates the weekly window before the session window (an exhausted weekly
    /// limit blocks even when the 5h window is open), and fails closed when the
    /// session window is absent — an account with no readable session limit
    /// cannot be proven available.
    static func classify(_ metrics: UsageMetrics) -> WakeQuota {
        if let weekly = metrics.weeklyLimit, weekly.isAtLimit {
            return .blocked(until: weekly.resetTime, reason: .weeklyLimit)
        }
        if let codeReview = metrics.codeReviewLimit, codeReview.isAtLimit {
            return .blocked(until: codeReview.resetTime, reason: .modelWeeklyLimit)
        }
        guard let session = metrics.sessionLimit else {
            return .unknown(reason: "no session-limit window in metrics")
        }
        if session.isAtLimit {
            return .blocked(until: session.resetTime, reason: .sessionLimit)
        }
        return .available
    }
}
