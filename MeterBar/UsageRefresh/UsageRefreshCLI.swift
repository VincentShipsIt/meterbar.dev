import Foundation
import MeterBarShared

/// Public facade used by the bundled `meterbar refresh` command.
public enum UsageRefreshCLI {
    // Read from nonisolated parsing and cleanup code, so they cannot inherit
    // the package's MainActor default isolation.
    public nonisolated static let defaultTimeout: TimeInterval = 60
    public nonisolated static let minimumTimeout: TimeInterval = 1
    public nonisolated static let maximumTimeout: TimeInterval = 600
    /// Ceiling on how long a caller waits for an over-running refresh to let go
    /// of the cross-process lock. The JSON is already on standard output by
    /// then, so this only bounds how long the process lingers.
    public nonisolated static let maximumCleanupWait: TimeInterval = 5

    public nonisolated struct Result: Sendable {
        public let jsonOutput: String
        public let summaryLine: String
        public let message: String?
        public let exitCode: Int32
        /// Non-nil when the refresh outlived its deadline and still holds the
        /// cross-process lock. Await it — bounded — before exiting.
        public let pendingCleanup: Task<Void, Never>?

        public init(
            jsonOutput: String,
            summaryLine: String,
            message: String?,
            exitCode: Int32,
            pendingCleanup: Task<Void, Never>? = nil
        ) {
            self.jsonOutput = jsonOutput
            self.summaryLine = summaryLine
            self.message = message
            self.exitCode = exitCode
            self.pendingCleanup = pendingCleanup
        }

        /// Waits for the in-flight refresh to release the lock, giving up after
        /// `timeout`. Giving up leaves the release to process teardown, which is
        /// the old behaviour — but only for a provider that ignored cancellation
        /// for a full ceiling, not for every timeout.
        public func awaitPendingCleanup(
            timeout: TimeInterval = UsageRefreshCLI.maximumCleanupWait
        ) async {
            guard let pendingCleanup else { return }
            let gate = CleanupGate()
            // `await someTask.value` ignores the awaiting context's
            // cancellation, so the ceiling needs its own racing task rather
            // than a cancelled task group.
            let observer = Task {
                _ = await pendingCleanup.value
                await gate.open()
            }
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await gate.open()
            }
            await gate.wait()
            observer.cancel()
            deadline.cancel()
        }
    }

    /// Either an already-validated timeout or the raw `--timeout` text.
    ///
    /// The CLI hands over the text unparsed so a malformed value is reported by
    /// the same JSON contract as every other refresh outcome, instead of by
    /// ArgumentParser's pre-`run()` usage error. See `RefreshTimeout`.
    public nonisolated enum TimeoutSource: Equatable, Sendable {
        case text(String?)
        case resolved(TimeInterval)

        func resolve() -> Swift.Result<TimeInterval, RefreshCLIFailure> {
            switch self {
            case let .text(raw): return RefreshTimeout.resolve(raw)
            case let .resolved(value): return .success(value)
            }
        }
    }

    public nonisolated struct Request: Sendable {
        public let timeout: TimeoutSource
        public let shouldCancel: @Sendable () -> Bool

        public init(
            timeout: TimeInterval = defaultTimeout,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) {
            self.timeout = .resolved(timeout)
            self.shouldCancel = shouldCancel
        }

        public init(
            timeoutText: String?,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) {
            timeout = .text(timeoutText)
            self.shouldCancel = shouldCancel
        }
    }

    public static func run(_ request: Request) async -> Result {
        let sharedStore = SharedDataStore.shared
        let timeout: TimeInterval
        switch request.timeout.resolve() {
        case let .success(value):
            timeout = value
        case let .failure(failure):
            return result(from: RefreshCLIResponse(
                failure: failure,
                collectedAt: Date(),
                cachedMetrics: sharedStore.loadMetrics()
            ))
        }

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
            timeout: timeout,
            refresh: { await manager.refreshAll(trigger: .userInitiated) },
            cacheSnapshot: {
                sharedStore.flushPendingWrites()
                return sharedStore.loadMetrics()
            },
            shouldCancel: request.shouldCancel
        )
        let outcome = await engine.run()
        return result(from: outcome.response, pendingCleanup: outcome.pendingCleanup)
    }

    static func makeLock() -> WakeLock {
        UsageRefreshLock.make(holderKind: .cli)
    }

    static func lockURL() -> URL {
        UsageRefreshLock.lockURL()
    }

    @MainActor
    private static func makeManager(
        sharedStore: SharedDataStore,
        configuration: UsageRefreshConfigurationStore.Snapshot
    ) -> UsageDataManager {
        UsageDataManager(
            claudeCodeAccountStore: ClaudeCodeAccountStore(accounts: configuration.claudeAccounts),
            codexAccountStore: CodexAccountStore(accounts: configuration.codexAccounts),
            grokAccountStore: GrokAccountStore(accounts: configuration.grokAccounts),
            providerVisibilityStore: ProviderVisibilityStore(hiddenServices: configuration.hiddenServices),
            sharedStore: sharedStore,
            cacheDefaults: UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) ?? .standard,
            schedulesAutoRefresh: false,
            refreshLockMode: .externallyOwned
        )
    }

    private static func result(
        from response: RefreshCLIResponse,
        pendingCleanup: Task<Void, Never>? = nil
    ) -> Result {
        let json = (try? response.jsonString()) ?? "{}"
        return Result(
            jsonOutput: json,
            summaryLine: response.summaryLine,
            message: response.message,
            exitCode: response.outcome.exitCode,
            pendingCleanup: pendingCleanup
        )
    }
}

private actor CleanupGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
