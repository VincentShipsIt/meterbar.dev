import Foundation

/// Whether a usage manager takes the shared refresh lock itself or runs under
/// an outer owner such as `UsageRefreshEngine` in the bundled CLI.
nonisolated enum UsageRefreshLockMode: Equatable, Sendable {
    case acquirePerRefresh
    case externallyOwned
}

/// The one lock path and construction policy shared by the app and CLI.
nonisolated enum UsageRefreshLock {
    static func make(holderKind: WakeLockHolder.Kind) -> WakeLock {
        WakeLock(lockURL: lockURL(), legacyLockURLs: [], holderKind: holderKind)
    }

    static func lockURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("usage-refresh", isDirectory: true)
            .appendingPathComponent("refresh.lock")
    }
}
