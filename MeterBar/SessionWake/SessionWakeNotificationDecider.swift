import Foundation

/// Inputs that gate a Session Wake notification. Pure value so the decision is
/// trivially testable and free of store/singleton coupling.
struct SessionWakeNotificationContext: Equatable, Sendable {
    /// The global notifications master switch (NotificationPreferencesStore).
    let globalNotificationsEnabled: Bool
    /// Whether the Claude provider is visible/enabled (ProviderVisibilityStore).
    let claudeProviderEnabled: Bool
    /// The Session Wake "notify on completion" preference.
    let notifyOnCompletion: Bool
}

/// Decides whether Session Wake may post a notification. A wake notification is
/// suppressed unless the global switch, the Claude provider, and the Session
/// Wake preference all allow it — Session Wake never overrides the user's global
/// or provider-level choices.
enum SessionWakeNotificationDecider {
    static func shouldNotifyOnCompletion(_ context: SessionWakeNotificationContext) -> Bool {
        context.globalNotificationsEnabled
            && context.claudeProviderEnabled
            && context.notifyOnCompletion
    }

    /// Whether a "watch started" notification may post. Same gate; watch-start
    /// notifications are informational and never bypass the global/provider gate.
    static func shouldNotifyOnWatchStart(_ context: SessionWakeNotificationContext) -> Bool {
        shouldNotifyOnCompletion(context)
    }
}
