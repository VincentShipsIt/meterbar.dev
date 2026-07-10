import Foundation
import MeterBarShared

/// Every UserDefaults key the app persists, in one place.
///
/// These were previously inline string literals scattered across six files —
/// a typo in any one of them silently reads/writes the wrong key.
enum StorageKeys {
    /// Cached `[ServiceType: UsageMetrics]` blob (also the app-group file's
    /// base name — see SharedDataStore). Single-sourced from `MeterBarShared`
    /// so the app, widget, and CLI can't drift on the key.
    static let cachedUsageMetrics = SharedMetricsStore.metricsKey
    /// Auto-refresh interval raw value (RefreshInterval).
    static let refreshInterval = "refreshInterval"
    /// Raw values of ServiceTypes the user has hidden.
    static let hiddenProviderServices = "HiddenProviderServices"
    /// Whether the Dock icon is shown (menu bar item is unaffected).
    static let showInDock = "ShowMeterBarInDock"
    /// Enables the legacy Claude Code OAuth fallback when the CLI is unavailable.
    static let claudeCodeOAuthFallback = "ClaudeCodeEnableOAuthFallback"
    /// Extra Claude Code account profiles (JSON-encoded [ClaudeCodeAccount]).
    static let claudeCodeCustomAccounts = "ClaudeCodeCustomAccounts"
    /// User-chosen display name for the default Claude Code CLI profile.
    static let claudeCodeDefaultAccountName = "ClaudeCodeDefaultAccountName"
    /// Persisted account display order (array of UUID strings).
    static let claudeCodeAccountOrder = "ClaudeCodeAccountOrder"
    /// Global on/off switch for usage notifications.
    static let notificationsEnabled = "NotificationsEnabled"
    /// Raw value of the `NotificationThreshold` at which a warning notifies.
    static let notificationWarningThreshold = "NotificationWarningThreshold"
    /// Raw value of the `NotificationThreshold` at which a critical alert notifies.
    static let notificationCriticalThreshold = "NotificationCriticalThreshold"

    // MARK: Session Wake (issue #98)

    /// Master switch: whether the Session Wake feature is enabled at all.
    static let sessionWakeFeatureEnabled = "SessionWakeFeatureEnabled"
    /// Runtime intent: whether the quota watcher is armed. Separate from feature
    /// enablement so a user can keep the feature configured but the watcher off.
    static let sessionWakeWatcherArmed = "SessionWakeWatcherArmed"
    /// UUID string of the explicitly-selected wake account. Never inferred from
    /// account order or recent activity.
    static let sessionWakeAccountID = "SessionWakeAccountID"
    /// Whether the user completed the first-enable safety acknowledgement.
    static let sessionWakeFirstEnableAcknowledged = "SessionWakeFirstEnableAcknowledged"
    /// Whether the user separately acknowledged permission bypass for resumes.
    static let sessionWakePermissionBypassAcknowledged = "SessionWakePermissionBypassAcknowledged"
    /// Whether to notify when a wake run completes.
    static let sessionWakeNotifyOnCompletion = "SessionWakeNotifyOnCompletion"
    /// Whether to notify when the watcher starts waiting for a reset.
    static let sessionWakeNotifyOnWatchStart = "SessionWakeNotifyOnWatchStart"
}
