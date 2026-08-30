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
    /// Explicit opt-in for holding a user-idle system-sleep assertion while a
    /// tracked provider still has session quota. Missing means off.
    static let stayAwakeEnabled = "StayAwakeEnabled"
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

    // MARK: - Follow Focused App (#341)

    /// Explicit opt-in for merged-mode focus following (Bool, default off).
    /// Mutually exclusive with pinning: enabling it clears the pin, and pinning
    /// turns it back off.
    static let statusItemFollowsFocusedApp = "StatusItemFollowsFocusedApp"
    /// JSON-encoded `[String: ServiceType]` mapping app bundle identifiers to
    /// providers. Missing means "never edited" and yields
    /// `MenuBarFocusAppCatalog.defaultMapping`; an empty dictionary is a
    /// deliberate "nothing mapped" and is preserved as written.
    static let statusItemFocusAppMapping = "StatusItemFocusAppMapping"
    /// `ResetTimeFormat` raw value for reset labels in popover cards.
    static let popoverResetTimeFormat = "PopoverResetTimeFormat"
    /// Opt-in for the one-line "what to use next" hint at the top of the popover.
    /// Absent means off: the full ranking already lives in the dashboard's
    /// Optimize tab, so the popover keeps its pre-feature layout by default.
    static let popoverShowsRecommendationHint = "PopoverShowsRecommendationHint"
    /// Opt-in timed rotation of the merged status item through visible providers.
    static let statusItemRotatesProviders = "StatusItemRotatesProviders"
    /// `StatusItemRotationInterval` raw value: seconds between rotation steps.
    static let statusItemRotationInterval = "StatusItemRotationIntervalSeconds"
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
    /// Providers whose ordered tracked-account chain may automatically fail over.
    /// Missing means disabled for every provider.
    static let accountFailoverEnabledProviders = "AccountFailoverEnabledProviders"
    /// Last live logical account per failover-capable provider. Contains UUIDs only.
    static let accountFailoverActiveAccounts = "AccountFailoverActiveAccounts"
    /// Extra Grok Build profiles (JSON-encoded [GrokAccount]).
    static let grokCustomAccounts = "GrokCustomAccounts"
    /// User-chosen display name for the default Grok Build profile.
    static let grokDefaultAccountName = "GrokDefaultAccountName"
    /// Whether the synthesized default Grok profile participates in tracking.
    static let grokDefaultAccountEnabled = "GrokDefaultAccountEnabled"
    /// Persisted Grok account display order (array of UUID strings).
    static let grokAccountOrder = "GrokAccountOrder"
    /// Cached per-account Grok metrics (JSON-encoded [UUID: UsageMetrics]).
    static let cachedGrokAccountMetrics = "CachedGrokAccountMetrics"
    /// Extra OpenRouter API keys (JSON-encoded [OpenRouterAccount]). Key
    /// material lives in the Keychain, never here.
    static let openRouterCustomAccounts = "OpenRouterCustomAccounts"
    /// User-chosen display name for the default OpenRouter key.
    static let openRouterDefaultAccountName = "OpenRouterDefaultAccountName"
    /// Whether the synthesized default OpenRouter key participates in tracking.
    static let openRouterDefaultAccountEnabled = "OpenRouterDefaultAccountEnabled"
    /// Persisted OpenRouter key display order (array of UUID strings).
    static let openRouterAccountOrder = "OpenRouterAccountOrder"
    /// Cached per-key OpenRouter metrics (JSON-encoded [UUID: UsageMetrics]).
    static let cachedOpenRouterAccountMetrics = "CachedOpenRouterAccountMetrics"
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
    /// Versioned app-wide quota event integration configuration. The migration
    /// reads `sessionWakeEventHooks` once, then this key becomes authoritative.
    static let quotaEventIntegrations = "QuotaEventIntegrationsV1"

    /// `CostWindowSelection` raw value (7, 30, or -1 for month-to-date): the Costs page reporting
    /// window. Missing or unknown means the 30-day view.
    static let costsWindowDays = "CostsWindowDays"

    // MARK: - Display Currency (#270)

    /// `DisplayCurrencySelection` raw value. Missing or unknown means USD.
    static let displayCurrencySelection = "DisplayCurrencySelection"
    /// Display currency code/label. Presentation only — stored and exported
    /// cost data always stays USD.
    static let displayCurrencyCode = "DisplayCurrencyCode"
    /// Units of `displayCurrencyCode` per 1 USD.
    static let displayCurrencyRate = "DisplayCurrencyRate"
    /// Manual entry time or official reference date for the saved rate.
    static let displayCurrencyEnteredAt = "DisplayCurrencyEnteredAt"
    /// `DisplayCurrencySource` raw value. Missing or unrecognized (a retired
    /// case from an older build) migrates to `.manual`.
    static let displayCurrencySource = "DisplayCurrencySource"
    /// Legacy automatic-mode flag retained for migration from 1.8.35.
    static let displayCurrencyAutomatic = "DisplayCurrencyAutomatic"
    /// Last successful automatic refresh, used to cap fetches at once per day.
    static let displayCurrencyLastRefreshAt = "DisplayCurrencyLastRefreshAt"
}
