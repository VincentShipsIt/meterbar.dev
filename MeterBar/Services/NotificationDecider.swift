import Foundation
import MeterBarShared

/// Which of the two notification levels a quota crossing produces.
enum NotificationLevel: String, Equatable, Sendable {
    /// Early warning — the quota entered the user's warning band.
    case warning
    /// Alert — the quota entered the user's critical band.
    case critical
}

/// A single notification the decider decided should be posted this cycle.
///
/// Carries only what the delegate needs to compose copy; the delegate owns the
/// actual `UNUserNotificationCenter` interaction so this stays pure.
struct FiredNotification: Equatable, Sendable {
    /// Stable identifier — re-posting the same id replaces the pending banner
    /// instead of stacking a new one, and dedupes repeat crossings.
    let key: String
    let level: NotificationLevel
    let serviceDisplayName: String
    /// Clamped `0...100` percentage used, for the warning body copy.
    let percentUsed: Int
}

/// The result of evaluating one service's metrics: the notifications to post and
/// the updated set of already-notified keys (threaded back into the next cycle).
struct NotificationEvaluation: Equatable, Sendable {
    let notifications: [FiredNotification]
    let notifiedKeys: Set<String>
}

/// Pure threshold-crossing decision extracted from `AppDelegate.checkAndNotify`.
///
/// Given a service's metrics, the user's preferences, and the set of bands
/// already notified, it decides — deterministically, with no side effects and no
/// hidden clock — which notifications should fire and how the dedup key set
/// should change. This is the unit under test for the crossing matrix
/// (rising / falling / repeat / threshold-change), plus the global-off,
/// provider-disabled, and staleness gates.
struct NotificationDecider {
    let preferences: NotificationPreferences
    /// Cached metrics older than this (relative to `now`) never notify, so a
    /// stale on-disk cache from a previous session can't fire alerts about a
    /// quota that may since have reset.
    let stalenessThreshold: TimeInterval

    /// One hour: comfortably longer than every non-manual refresh interval
    /// (max 30 min), so fresh data is never mistaken for stale, while still
    /// suppressing genuinely ancient cached values.
    static let defaultStalenessThreshold: TimeInterval = 3_600

    init(
        preferences: NotificationPreferences,
        stalenessThreshold: TimeInterval = NotificationDecider.defaultStalenessThreshold
    ) {
        self.preferences = preferences
        self.stalenessThreshold = stalenessThreshold
    }

    func evaluate(
        metrics: UsageMetrics,
        providerEnabled: Bool,
        alreadyNotified: Set<String>,
        now: Date = Date()
    ) -> NotificationEvaluation {
        // Gate 1: notifications turned off globally.
        guard preferences.isEnabled else {
            return NotificationEvaluation(notifications: [], notifiedKeys: alreadyNotified)
        }

        // Gate 2: never notify for a provider the user has disabled.
        guard providerEnabled else {
            return NotificationEvaluation(notifications: [], notifiedKeys: alreadyNotified)
        }

        // Gate 3: never notify off stale cached data.
        guard now.timeIntervalSince(metrics.lastUpdated) <= stalenessThreshold else {
            return NotificationEvaluation(notifications: [], notifiedKeys: alreadyNotified)
        }

        let limits: [(limit: UsageLimit, type: String)] = [
            (metrics.sessionLimit, "session"),
            (metrics.weeklyLimit, "weekly"),
            (metrics.codeReviewLimit, "codeReview")
        ].compactMap { pair in pair.0.map { ($0, pair.1) } }

        var keys = alreadyNotified
        var fired: [FiredNotification] = []

        let warningRank = Self.severityRank(preferences.warningThreshold.band)
        let criticalRank = Self.severityRank(preferences.criticalThreshold.band)

        for (limit, limitType) in limits {
            let baseKey = "\(metrics.service.rawValue)-\(limitType)"
            let warnKey = "\(baseKey)-warn"
            let criticalKey = "\(baseKey)-critical"

            let bandRank = Self.severityRank(QuotaBand.forLimit(limit))

            if bandRank >= criticalRank {
                // In (or past) the critical band. Supersede any pending warn
                // alert, then fire once per crossing.
                keys.remove(warnKey)
                if keys.insert(criticalKey).inserted {
                    fired.append(FiredNotification(
                        key: criticalKey,
                        level: .critical,
                        serviceDisplayName: metrics.service.displayName,
                        percentUsed: Int(limit.percentage)
                    ))
                }
            } else if bandRank >= warningRank {
                // In the warning band but not yet critical.
                if keys.insert(warnKey).inserted {
                    fired.append(FiredNotification(
                        key: warnKey,
                        level: .warning,
                        serviceDisplayName: metrics.service.displayName,
                        percentUsed: Int(limit.percentage)
                    ))
                }
            } else {
                // Fell back below both thresholds; allow the next crossing to
                // notify again.
                keys.remove(warnKey)
                keys.remove(criticalKey)
            }
        }

        return NotificationEvaluation(notifications: fired, notifiedKeys: keys)
    }

    /// Orders the shared quota bands by severity so a user-selected threshold
    /// band can be compared against a limit's current band. This only ranks the
    /// existing `QuotaBand` cases — it is not a second threshold scheme.
    private static func severityRank(_ band: QuotaBand) -> Int {
        switch band {
        case .healthy: return 0
        case .tight: return 1
        case .critical: return 2
        case .exhausted: return 3
        }
    }
}
