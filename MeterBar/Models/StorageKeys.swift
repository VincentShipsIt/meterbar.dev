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
    /// OpenRouter is API-key backed and must be explicitly enabled.
    static let openRouterProviderEnabled = "OpenRouterProviderEnabled"
    /// Grok Build is tracked by default; this key records an explicit opt-out.
    /// Absent means enabled — see `ProviderVisibilityStore.load()`, which must
    /// distinguish "never touched" from "turned off" now that the default flipped.
    static let grokProviderEnabled = "GrokProviderEnabled"
    /// Whether the Dock icon is shown (menu bar item is unaffected).
    static let showInDock = "ShowMeterBarInDock"
    /// Stable provider/account/window key pinned into the menu bar title. Missing means Auto.
    static let statusItemPinnedCandidate = "StatusItemPinnedCandidate"
    /// `MenuBarPresentationMode` raw value: one merged status item or one per provider.
    static let statusItemPresentationMode = "StatusItemPresentationMode"
    /// `StatusItemLabelMetric` raw value (percent left, percent used, or icon only).
    static let statusItemLabelMetric = "StatusItemLabelMetric"
    /// `StatusItemLabelSize` raw value (compact or regular).
    static let statusItemLabelSize = "StatusItemLabelSize"
    /// `StatusItemWindowMode` raw value (selected window or combined session + weekly).
    static let statusItemWindowMode = "StatusItemWindowMode"
    /// `StatusItemFontSize` raw value. Missing preserves AppKit's native status-item font.
    static let statusItemFontSize = "StatusItemFontSize"
    /// Explicit opt-in for maximum black/white status-item contrast.
    static let statusItemHighContrast = "StatusItemHighContrast"
    /// Replaces an exhausted quota value with its reset countdown when available.
    static let statusItemShowsExhaustedResetCountdown = "StatusItemShowsExhaustedResetCountdown"
    /// `ResetTimeFormat` raw value for reset labels in popover cards.
    static let popoverResetTimeFormat = "PopoverResetTimeFormat"
    /// Accounts that each get their own status item ([String] of MenuBarAccountKey),
    /// in the order the user selected them.
    static let menuBarSelectedAccountKeys = "MenuBarSelectedAccountKeys"
    /// Account the merged status item is currently bound to (MenuBarAccountKey).
    static let menuBarMergedAccountKey = "MenuBarMergedAccountKey"
    /// Whether the one-time first-launch popover has been completed or dismissed.
    static let hasCompletedFirstRun = "HasCompletedFirstRun"
    /// Hidden opt-in for demo / sample-data mode. When set (or `METERBAR_DEMO=1`
    /// in the environment) the app publishes synthetic `DemoData` instead of the
    /// signed-in account's real usage, for landing-page screenshots and the
    /// first-run onboarding preview. Off by default; never affects real data.
    static let demoMode = "DemoMode"
    /// Enables the Claude Code OAuth usage source (`/api/oauth/usage`), the
    /// primary reader for the default account. On by default; off forces the CLI
    /// output fallback. Legacy key name kept to preserve existing user settings.
    static let claudeCodeOAuthFallback = "ClaudeCodeEnableOAuthFallback"
    /// Extra Claude Code account profiles (JSON-encoded [ClaudeCodeAccount]).
    static let claudeCodeCustomAccounts = "ClaudeCodeCustomAccounts"
    /// User-chosen display name for the default Claude Code CLI profile.
    static let claudeCodeDefaultAccountName = "ClaudeCodeDefaultAccountName"
    /// User-chosen config directory for the default Claude Code CLI profile.
    static let claudeCodeDefaultConfigDirectory = "ClaudeCodeDefaultConfigDirectory"
    /// Per-account delegated OAuth-refresh outcome and completion time.
    static let claudeCodeRefreshCooldowns = "ClaudeCodeRefreshCooldowns"
    /// Per-Keychain-service timestamps used to suppress repeated background
    /// authorization attempts. Contains no credential material.
    static let claudeCodeKeychainDenials = "ClaudeCodeKeychainDenials"
    /// Whether the synthesized default Claude Code CLI profile participates in tracking.
    static let claudeCodeDefaultAccountEnabled = "ClaudeCodeDefaultAccountEnabled"
    /// Persisted account display order (array of UUID strings).
    static let claudeCodeAccountOrder = "ClaudeCodeAccountOrder"
    /// Privacy-safe, profile-attributed Fable session metadata.
    static let claudeFableSessions = "ClaudeFableSessions"
    /// Cached per-account Claude Code metrics (JSON-encoded [UUID: UsageMetrics]).
    static let cachedClaudeCodeAccountMetrics = "CachedClaudeCodeAccountMetrics"
    /// Extra Codex CLI account profiles (JSON-encoded [CodexAccount]).
    static let codexCustomAccounts = "CodexCustomAccounts"
    /// User-chosen display name for the default Codex CLI profile.
    static let codexDefaultAccountName = "CodexDefaultAccountName"
    /// User-chosen CODEX_HOME override for the default Codex CLI profile.
    static let codexDefaultHomeDirectory = "CodexDefaultHomeDirectory"
    /// Whether the synthesized default Codex CLI profile participates in tracking.
    static let codexDefaultAccountEnabled = "CodexDefaultAccountEnabled"
    /// Persisted Codex account display order (array of UUID strings).
    static let codexAccountOrder = "CodexAccountOrder"
    /// Cached per-account Codex metrics (JSON-encoded [UUID: UsageMetrics]).
    static let cachedCodexAccountMetrics = "CachedCodexAccountMetrics"
    /// Global on/off switch for usage notifications.
    static let notificationsEnabled = "NotificationsEnabled"
    /// Raw value of the `NotificationThreshold` at which a warning notifies.
    static let notificationWarningThreshold = "NotificationWarningThreshold"
    /// Raw value of the `NotificationThreshold` at which a critical alert notifies.
    static let notificationCriticalThreshold = "NotificationCriticalThreshold"

    // MARK: - Session Wake (#98)

    /// Master enablement for Session Wake. Missing stays on for v1.7 compatibility;
    /// an explicit false is the emergency kill-switch shared with the CLI.
    static let sessionWakeFeatureEnabled = "SessionWakeFeatureEnabled"
    /// Runtime intent for the watcher, distinct from feature enablement (Bool).
    static let sessionWakeWatcherArmed = "SessionWakeWatcherArmed"
    /// The active wake provider raw value (`WakeProvider`, default `.claude`).
    static let sessionWakeProvider = "SessionWakeProvider"
    /// Explicitly selected Claude wake account id (UUID string). Never inferred.
    static let sessionWakeAccountID = "SessionWakeAccountID"
    /// Explicitly selected Codex wake account id (UUID string). Never inferred.
    static let sessionWakeCodexAccountID = "SessionWakeCodexAccountID"
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
    /// JSON-encoded `WakeEventHookConfiguration`; missing means no configured or enabled hooks.
    static let sessionWakeEventHooks = "SessionWakeEventHooks"

    // MARK: - Display Currency (#270)

    /// User-typed currency code/label (e.g. "EUR"). Presentation only — stored
    /// and exported cost data always stays USD. Missing means "no conversion,
    /// show USD" — the default.
    static let displayCurrencyCode = "DisplayCurrencyCode"
    /// User-supplied units of `displayCurrencyCode` per 1 USD. MeterBar never
    /// fetches this from a live/network source.
    static let displayCurrencyRate = "DisplayCurrencyRate"
    /// When the user entered the rate above. Shown next to every converted
    /// figure so it can never be mistaken for a live quote.
    static let displayCurrencyEnteredAt = "DisplayCurrencyEnteredAt"
}
