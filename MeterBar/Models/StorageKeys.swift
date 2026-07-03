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
}
