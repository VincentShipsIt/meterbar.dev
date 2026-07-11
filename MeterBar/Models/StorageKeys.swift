import Foundation
import MeterBarShared

/// Every UserDefaults key the app persists, in one place.
///
/// These were previously inline string literals scattered across six files —
/// a typo in any one of them silently reads/writes the wrong key.
nonisolated enum StorageKeys {
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

    // MARK: - Session Wake (#98)

    /// Master enablement for the Session Wake feature (Bool, default off).
    static let sessionWakeFeatureEnabled = "SessionWakeFeatureEnabled"
    /// Runtime intent for the watcher, distinct from feature enablement (Bool).
    static let sessionWakeWatcherArmed = "SessionWakeWatcherArmed"
    /// Explicitly selected wake account id (UUID string). Never inferred.
    static let sessionWakeAccountID = "SessionWakeAccountID"
    /// Whether the user completed the first-enable safety acknowledgement (Bool).
    static let sessionWakeFirstEnableAcknowledged = "SessionWakeFirstEnableAcknowledged"
    /// Whether the user separately acknowledged permission-bypass mode (Bool).
    static let sessionWakeBypassAcknowledged = "SessionWakeBypassAcknowledged"
    /// Permission posture raw value (`WakePermissionMode`).
    static let sessionWakePermissionMode = "SessionWakePermissionMode"
    /// Resume prompt text.
    static let sessionWakePrompt = "SessionWakePrompt"
    /// Notify when a wake run completes (Bool, default on).
    static let sessionWakeNotifyOnCompletion = "SessionWakeNotifyOnCompletion"
    /// Max sessions resumed per run (Int).
    static let sessionWakeMaxSessionsPerRun = "SessionWakeMaxSessionsPerRun"
    /// Per-session max agent turns (Int).
    static let sessionWakeMaxTurns = "SessionWakeMaxTurns"
}
