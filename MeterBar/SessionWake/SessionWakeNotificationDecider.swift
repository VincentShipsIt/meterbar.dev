import Foundation

/// A Session Wake notification the decider decided should be posted.
///
/// Mirrors `FiredNotification` (the quota-crossing analogue): the decider stays
/// pure and the app delegate owns the `UNUserNotificationCenter` interaction.
struct FiredWakeNotification: Equatable, Sendable {
    /// Stable identifier — re-posting the same id replaces the banner rather
    /// than stacking a duplicate.
    let key: String
    let title: String
    let body: String
}

/// Decides — deterministically, with no side effects — whether a Session Wake
/// event should surface a notification, honoring three independent gates
/// (issue #98 acceptance criterion):
///
/// 1. the **global** usage-notification switch (`NotificationPreferences`),
/// 2. **provider visibility** — Session Wake is Claude-only in v1, so a hidden
///    Claude Code provider suppresses its notifications, and
/// 3. the **Session Wake** per-event preferences (`notifyOnWatchStart` /
///    `notifyOnCompletion`).
///
/// Every gate must pass; any one being off returns `nil`.
struct SessionWakeNotificationDecider {
    /// The three gate axes plus the per-event Session Wake toggles, as a pure
    /// value so callers can assemble it from their stores without this type
    /// reaching into singletons.
    struct Gates: Equatable, Sendable {
        /// Global usage-notification switch (`NotificationPreferencesStore`).
        let notificationsEnabled: Bool
        /// Whether the Claude Code provider is visible (`ProviderVisibilityStore`).
        let claudeProviderEnabled: Bool
        /// Session Wake "notify when watching starts" preference.
        let notifyOnWatchStart: Bool
        /// Session Wake "notify on completion" preference.
        let notifyOnCompletion: Bool
    }

    /// A notification fired when the watcher begins waiting for a reset.
    func watchStartNotification(queuedCount: Int, gates: Gates) -> FiredWakeNotification? {
        guard gates.notificationsEnabled,
              gates.claudeProviderEnabled,
              gates.notifyOnWatchStart else {
            return nil
        }

        let noun = queuedCount == 1 ? "session" : "sessions"
        return FiredWakeNotification(
            key: "session-wake-watch-start",
            title: "Session Wake — Watching for Reset",
            body: "Watching for the Claude quota reset — \(queuedCount) \(noun) queued."
        )
    }

    /// A notification fired when a wake run completes, summarizing the outcome.
    func completionNotification(
        summary: SessionWakeRunSummary,
        gates: Gates
    ) -> FiredWakeNotification? {
        guard gates.notificationsEnabled,
              gates.claudeProviderEnabled,
              gates.notifyOnCompletion else {
            return nil
        }

        let sessionNoun = summary.attempted == 1 ? "session" : "sessions"
        var body = "Resumed \(summary.resumed) of \(summary.attempted) Claude \(sessionNoun)."
        if summary.failed > 0 {
            let failNoun = summary.failed == 1 ? "failure" : "failures"
            body += " \(summary.failed) \(failNoun)."
        }

        return FiredWakeNotification(
            key: "session-wake-completion",
            title: "Session Wake — Run Complete",
            body: body
        )
    }
}
