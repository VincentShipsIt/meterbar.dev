import Foundation

/// Single owner of the App Group location for `cached_usage_metrics.json` — the
/// identifier, file name, and the read path shared by the app, the widget
/// extension, and the CLI.
///
/// Previously the widget kept its own private `SharedDataStore` with forked
/// copies of the app-group identifier and metrics-key literals (issue #13); a
/// rename on one side silently broke cross-target reads. The constants now live
/// here so all three targets resolve the same file.
///
/// The app-side `SharedDataStore` still owns the *write* path and widget-timeline
/// reloads; every reader (widget, CLI) loads through this type.
public enum SharedMetricsStore {
    /// App Group identifier configured on the app and widget entitlements.
    public static let appGroupIdentifier = "group.dev.meterbar.app"

    /// Base name (no extension) of the cached-metrics blob. Also the app's
    /// in-process UserDefaults cache key (see `StorageKeys.cachedUsageMetrics`).
    public static let metricsKey = "cached_usage_metrics"
    public static let accountMetricsKey = "cached_usage_account_metrics"
    public static let parseHealthKey = "provider_parse_health_v1"
    public static let fableSessionsKey = "claude_fable_sessions_v1"

    /// The shared App Group container, or `nil` when App Groups aren't
    /// provisioned for the running target.
    public static var containerURL: URL? {
        let fileManager = FileManager.default
        return resolvedContainerURL(
            entitledContainerURL: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ),
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            fileExists: fileManager.fileExists(atPath:)
        )
    }

    /// Non-sandboxed local builds can carry the App Group entitlement while
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` still returns
    /// `nil`. The app and bundled CLI must keep using the same existing
    /// container in that case or successful provider refreshes remain trapped
    /// in the app's private preferences cache.
    static func resolvedContainerURL(
        entitledContainerURL: URL?,
        homeDirectory: URL,
        fileExists: (String) -> Bool
    ) -> URL? {
        if let entitledContainerURL {
            return entitledContainerURL
        }

        let fallback = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
        return fileExists(fallback.path) ? fallback : nil
    }

    /// URL of the cached-metrics JSON file inside the shared container.
    public static var metricsFileURL: URL? {
        containerURL?.appendingPathComponent("\(metricsKey).json")
    }

    public static var accountMetricsFileURL: URL? {
        containerURL?.appendingPathComponent("\(accountMetricsKey).json")
    }

    public static var parseHealthFileURL: URL? {
        containerURL?.appendingPathComponent("\(parseHealthKey).json")
    }

    public static var fableSessionsFileURL: URL? {
        containerURL?.appendingPathComponent("\(fableSessionsKey).json")
    }

    /// Decode the cached metrics, tolerating a missing file or malformed entries
    /// (an unknown service key drops that entry, not the whole cache — see
    /// `MetricsCodec.decode`). Returns an empty map when nothing is readable.
    public static func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard let metricsFileURL,
              let data = try? Data(contentsOf: metricsFileURL) else {
            return [:]
        }
        return MetricsCodec.decode(data)
    }

    public static func loadAccountMetrics() -> [AccountUsageSnapshot] {
        guard let accountMetricsFileURL,
              let data = try? Data(contentsOf: accountMetricsFileURL),
              let decoded = try? JSONDecoder().decode([AccountUsageSnapshot].self, from: data) else {
            return []
        }
        return decoded
    }
}
