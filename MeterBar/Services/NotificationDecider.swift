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
    /// User-facing quota identity (Session, Weekly, Sonnet, or Code Review).
    /// Including it keeps simultaneous quota banners distinguishable.
    let quotaDisplayName: String
    /// Whether exhausting this quota prevents normal provider usage. Secondary
    /// quotas and subscription quotas covered by enabled extra usage do not.
    let blocksProvider: Bool
    /// Clamped `0...100` percentage used, for the warning body copy.
    let percentUsed: Int
    /// True only when the quota is actually fully spent. A user can configure
    /// the critical alert at 10% remaining, which must not claim exhaustion.
    let isExhausted: Bool

    var title: String {
        if level == .critical, isExhausted {
            let state = blocksProvider ? "Limit Reached" : "Quota Exhausted"
            return "\(serviceDisplayName) \(quotaDisplayName) \(state)"
        }
        let state = level == .warning ? "Usage Warning" : "Usage Alert"
        return "\(serviceDisplayName) \(quotaDisplayName) \(state)"
    }

    var body: String {
        if level == .critical, isExhausted {
            if blocksProvider {
                return "You've reached your \(quotaDisplayName.lowercased()) usage limit"
            }
            return "The \(quotaDisplayName.lowercased()) quota is exhausted; "
                + "this quota alone does not block all \(serviceDisplayName) usage"
        }
        return "Your \(quotaDisplayName.lowercased()) quota is at \(percentUsed)%"
    }
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
        // Delivery gates suppress banners, not state transitions. Continuing to
        // evolve band keys while notifications are disabled (or data is stale)
        // lets a recovery clear old keys so the next genuine upward crossing is
        // not silently suppressed.
        let mayDeliver = preferences.isEnabled
            && providerEnabled
            && now.timeIntervalSince(metrics.lastUpdated) <= stalenessThreshold

        let limits: [(limit: UsageLimit?, kind: QuotaKind)] = [
            (metrics.sessionLimit, .session),
            (metrics.weeklyLimit, .weekly),
            (metrics.codeReviewLimit, .codeReview)
        ]

        var keys = alreadyNotified
        var fired: [FiredNotification] = []

        let warningRank = Self.severityRank(preferences.warningThreshold.band)
        let criticalRank = Self.severityRank(preferences.criticalThreshold.band)

        for (limit, quotaKind) in limits {
            let baseKey = "\(metrics.service.rawValue)-\(quotaKind.rawValue)"
            let warnKey = "\(baseKey)-warn"
            let criticalKey = "\(baseKey)-critical"

            guard let limit else {
                keys.remove(warnKey)
                keys.remove(criticalKey)
                continue
            }

            let band = QuotaBand.forLimit(limit)
            let bandRank = Self.severityRank(band)
            let quotaDisplayName = quotaKind.displayName(for: metrics.service)
            let blocksProvider = quotaKind != .codeReview && metrics.extraUsage?.state != .on

            if bandRank >= criticalRank {
                // Preserve the warning key while critical. Otherwise falling
                // from exhausted to warning would look like a fresh rise and
                // fire a recovery notification.
                keys.insert(warnKey)
                if keys.insert(criticalKey).inserted, mayDeliver {
                    fired.append(FiredNotification(
                        key: criticalKey,
                        level: .critical,
                        serviceDisplayName: metrics.service.displayName,
                        quotaDisplayName: quotaDisplayName,
                        blocksProvider: blocksProvider,
                        percentUsed: Int(limit.percentage),
                        isExhausted: band == .exhausted
                    ))
                }
            } else if bandRank >= warningRank {
                // In the warning band but not yet critical.
                // Dropping below critical re-arms only the critical crossing;
                // keeping the warning key prevents a banner on recovery.
                keys.remove(criticalKey)
                if keys.insert(warnKey).inserted, mayDeliver {
                    fired.append(FiredNotification(
                        key: warnKey,
                        level: .warning,
                        serviceDisplayName: metrics.service.displayName,
                        quotaDisplayName: quotaDisplayName,
                        blocksProvider: blocksProvider,
                        percentUsed: Int(limit.percentage),
                        isExhausted: false
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

    /// Stable quota key plus provider-specific display copy. `codeReviewLimit`
    /// represents Sonnet-only usage for Claude and Code Review usage for Codex.
    private enum QuotaKind: String, Equatable, Sendable {
        case session
        case weekly
        case codeReview

        func displayName(for service: ServiceType) -> String {
            switch self {
            case .session:
                return "Session"
            case .weekly:
                return "Weekly"
            case .codeReview:
                return service == .claudeCode ? "Sonnet" : "Code Review"
            }
        }
    }
}
