import Foundation
import MeterBarShared

/// Public facade used by the bundled `meterbar refresh` command.
public enum UsageRefreshCLI {
    @MainActor
    private final class NoopFableSessionTracker: ClaudeFableSessionTracking {
        func scheduleRefresh(accounts _: [ClaudeCodeAccount]) {}
    }

    public static let defaultTimeout: TimeInterval = 60
    public static let minimumTimeout: TimeInterval = 1
    public static let maximumTimeout: TimeInterval = 600

    public struct Result: Sendable {
        public let jsonOutput: String
        public let summaryLine: String
        public let message: String?
        public let exitCode: Int32
    }

    public struct Request: Sendable {
        public let timeout: TimeInterval
        public let shouldCancel: @Sendable () -> Bool

        public init(
            timeout: TimeInterval = defaultTimeout,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) {
            self.timeout = timeout
            self.shouldCancel = shouldCancel
        }
    }

    public static func run(_ request: Request) async -> Result {
        let sharedStore = SharedDataStore.shared
        guard let configuration = UsageRefreshConfigurationStore.load() else {
            return result(from: RefreshCLIResponse(
                outcome: .refreshFailed,
                collectedAt: Date(),
                durationSeconds: 0,
                outcomes: [],
                cachedMetrics: sharedStore.loadMetrics(),
                message: "MeterBar refresh configuration is unavailable. Open the MeterBar app and try again."
            ))
        }
        let manager = makeManager(sharedStore: sharedStore, configuration: configuration)
        let engine = UsageRefreshEngine(
            lock: makeLock(),
            timeout: request.timeout,
            refresh: { await manager.refreshAll() },
            cacheSnapshot: {
                sharedStore.flushPendingWrites()
                return sharedStore.loadMetrics()
            },
            shouldCancel: request.shouldCancel
        )
        return result(from: await engine.run())
    }

    static func makeLock() -> WakeLock {
        WakeLock(lockURL: lockURL(), legacyLockURLs: [], holderKind: .cli)
    }

    static func lockURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("usage-refresh", isDirectory: true)
            .appendingPathComponent("refresh.lock")
    }

    @MainActor
    private static func makeManager(
        sharedStore: SharedDataStore,
        configuration: UsageRefreshConfigurationStore.Snapshot
    ) -> UsageDataManager {
        UsageDataManager(
            claudeCodeAccountStore: ClaudeCodeAccountStore(accounts: configuration.claudeAccounts),
            claudeFableSessionTracker: NoopFableSessionTracker(),
            codexAccountStore: CodexAccountStore(accounts: configuration.codexAccounts),
            providerVisibilityStore: ProviderVisibilityStore(hiddenServices: configuration.hiddenServices),
            sharedStore: sharedStore,
            cacheDefaults: UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) ?? .standard,
            schedulesAutoRefresh: false
        )
    }

    private static func result(from response: RefreshCLIResponse) -> Result {
        let json = (try? response.jsonString()) ?? "{}"
        return Result(
            jsonOutput: json,
            summaryLine: response.summaryLine,
            message: response.message,
            exitCode: response.outcome.exitCode
        )
    }
}
