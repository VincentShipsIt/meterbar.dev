import Foundation

/// Inputs that gate a Session Wake notification. Pure value so the decision is
/// trivially testable and free of store/singleton coupling.
struct SessionWakeNotificationContext: Equatable, Sendable {
    /// The global notifications master switch (NotificationPreferencesStore).
    let globalNotificationsEnabled: Bool
    /// Whether the active wake provider is visible/enabled (ProviderVisibilityStore).
    let providerEnabled: Bool
    /// The active wake provider's user-facing name, used in the completion copy.
    let providerDisplayName: String
    /// The Session Wake "notify on completion" preference.
    let notifyOnCompletion: Bool
}

/// A Session Wake notification the decider decided should be posted.
///
/// Mirrors `FiredNotification` (the quota-crossing analogue): the decider stays
/// pure and the app delegate owns the `UNUserNotificationCenter` interaction.
/// The `key` is stable so re-posting replaces the pending banner rather than
/// stacking a duplicate.
struct FiredWakeNotification: Equatable, Sendable {
    let key: String
    let title: String
    let body: String
}

/// Decides whether Session Wake may post a notification. A wake notification is
/// suppressed unless the global switch, the active provider, and the Session
/// Wake preference all allow it — Session Wake never overrides the user's global
/// or provider-level choices.
enum SessionWakeNotificationDecider {
    /// Stable identifier for the completion banner. Re-posting the same id
    /// replaces the pending request instead of stacking a new banner every run.
    static let completionKey = "session-wake-completion"

    static func shouldNotifyOnCompletion(_ context: SessionWakeNotificationContext) -> Bool {
        context.globalNotificationsEnabled
            && context.providerEnabled
            && context.notifyOnCompletion
    }

    /// Whether a "watch started" notification may post. Same gate; watch-start
    /// notifications are informational and never bypass the global/provider gate.
    static func shouldNotifyOnWatchStart(_ context: SessionWakeNotificationContext) -> Bool {
        shouldNotifyOnCompletion(context)
    }

    /// The completion notification for a finished run, or `nil` when any gate is
    /// closed. Copy is pluralized and surfaces failure and still-queued counts so
    /// the banner reads honestly whether the run fully drained the queue or the
    /// quota re-exhausted partway through.
    static func completionNotification(
        summary: WakeRunSummary,
        context: SessionWakeNotificationContext
    ) -> FiredWakeNotification? {
        guard shouldNotifyOnCompletion(context) else { return nil }
        // The continuous watcher ends EVERY rescan pass in .completed, and an
        // idle pass produces an all-zero summary — without this gate an armed
        // watcher with nothing to do would post (and replace any meaningful
        // banner with) "Resumed 0 of 0" every rescan interval, with sound.
        guard summary.attempted > 0 || summary.remaining > 0 else { return nil }

        let sessionNoun = summary.attempted == 1 ? "session" : "sessions"
        var body = "Resumed \(summary.resumed) of \(summary.attempted) \(context.providerDisplayName) \(sessionNoun)."
        if summary.failed > 0 {
            let failureNoun = summary.failed == 1 ? "failure" : "failures"
            body += " \(summary.failed) \(failureNoun)."
        }
        if summary.remaining > 0 {
            body += " \(summary.remaining) still queued."
        }

        return FiredWakeNotification(
            key: completionKey,
            title: "Session Wake — Run Complete",
            body: body
        )
    }
}
