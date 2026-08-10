import Foundation
import MeterBarShared

/// Public facade used by the bundled `meterbar guard` command.
///
/// Reads the cached app-group snapshot by default so a shell hook costs a file
/// read, not a provider round trip. `--refresh` opts into one bounded refresh
/// through the same coordinator `meterbar refresh` uses; guard never waits,
/// polls, or consumes reset credits (that is `meterbar wake`).
nonisolated public enum QuotaGuardCLI {
    public static let defaultProvider = "claude"
    public static let defaultWindow = "session"
    public static let defaultRefreshTimeout: TimeInterval = 20
    public static let minimumRefreshTimeout: TimeInterval = 1
    public static let maximumRefreshTimeout: TimeInterval = 600

    public struct Result: Sendable {
        public let jsonOutput: String
        public let summaryLine: String
        public let message: String?
        public let exitCode: Int32
    }

    public struct Request: Sendable {
        public let provider: String
        public let window: String
        /// Raw `--min-remaining` text. Parsed in the core, not in
        /// `validate()`, so a malformed value exits with the documented usage
        /// code instead of ArgumentParser's generic one.
        public let minRemaining: String?
        public let configDirectory: String?
        public let refresh: Bool
        /// Raw `--refresh-timeout` text, parsed in the core for the same reason
        /// as `minRemaining`. `nil` means `defaultRefreshTimeout`.
        public let refreshTimeout: String?
        /// Polled by `--refresh` so SIGINT/SIGTERM ends the refresh window
        /// cooperatively. Guard still evaluates the cached snapshot afterwards
        /// and exits with a documented guard code.
        public let shouldCancel: @Sendable () -> Bool

        public init(
            provider: String = defaultProvider,
            window: String = defaultWindow,
            minRemaining: String? = nil,
            configDirectory: String? = nil,
            refresh: Bool = false,
            refreshTimeout: String? = nil,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) {
            self.provider = provider
            self.window = window
            self.minRemaining = minRemaining
            self.configDirectory = configDirectory
            self.refresh = refresh
            self.refreshTimeout = refreshTimeout
            self.shouldCancel = shouldCancel
        }
    }

    public static func run(_ request: Request) async -> Result {
        let now = Date()
        let resolved = QuotaGuardTarget.resolve(
            provider: request.provider,
            window: request.window,
            minRemaining: request.minRemaining,
            configDirectory: request.configDirectory,
            refreshTimeout: request.refreshTimeout
        )

        let target: QuotaGuardTarget
        switch resolved {
        case let .failure(failure):
            return result(from: .failed(failure, checkedAt: now))
        case let .success(value):
            target = value
        }

        if request.refresh {
            // A failed refresh is not itself a guard failure: the cached
            // snapshot is still evaluated below, and reports its own staleness.
            await performRefresh(
                timeout: target.refreshTimeout,
                shouldCancel: request.shouldCancel
            )
        }

        return result(from: evaluate(target: target))
    }

    /// One bounded refresh through the coordinator the app and `meterbar
    /// refresh` share, so `--refresh` cannot start a second concurrent poll.
    @MainActor
    private static func performRefresh(
        timeout: TimeInterval,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async {
        let result = await UsageRefreshCLI.run(
            UsageRefreshCLI.Request(timeout: timeout, shouldCancel: shouldCancel)
        )
        // Guard keeps running after the refresh, so it must not leave the
        // cross-process lock held by an abandoned task while it evaluates the
        // snapshot and exits.
        await result.awaitPendingCleanup()
    }

    private static func evaluate(target: QuotaGuardTarget) -> QuotaGuardEvaluation {
        let store = SharedDataStore.shared
        store.flushPendingWrites()

        let selection = QuotaGuardAccountResolver.resolve(
            target: target,
            // Only the `--config-dir` path needs the account projection; the
            // provider-wide path stays a single cache read.
            configuration: target.configDirectory == nil ? nil : UsageRefreshConfigurationStore.load(),
            accountSnapshots: store.loadAccountMetrics(),
            providerMetrics: store.loadMetrics(),
            defaultDirectories: .current()
        )

        switch selection {
        case let .failure(failure):
            return .failed(failure, checkedAt: Date())
        case let .success(value):
            return QuotaGuardEvaluator.evaluate(
                target: target,
                account: value.account,
                metrics: value.metrics
            )
        }
    }

    private static func result(from evaluation: QuotaGuardEvaluation) -> Result {
        let response = GuardCLIResponse(evaluation: evaluation)
        return Result(
            jsonOutput: (try? response.jsonString()) ?? "{}",
            summaryLine: evaluation.summaryLine,
            // Success needs no second line; every other outcome explains itself
            // on stderr so `guard >/dev/null` still surfaces the reason.
            message: evaluation.outcome == .available ? nil : evaluation.message,
            exitCode: evaluation.exitCode
        )
    }
}
