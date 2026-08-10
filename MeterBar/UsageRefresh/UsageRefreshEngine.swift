import Foundation
import MeterBarShared

/// Bounded, non-overlapping wrapper around the app's refresh coordinator.
nonisolated struct UsageRefreshEngine {
    typealias RefreshOperation = @Sendable () async -> UsageRefreshReport
    typealias CacheSnapshot = @Sendable () -> [ServiceType: UsageMetrics]

    private let lock: WakeLock
    private let timeout: TimeInterval
    private let refresh: RefreshOperation
    private let cacheSnapshot: CacheSnapshot
    private let shouldCancel: @Sendable () -> Bool

    init(
        lock: WakeLock,
        timeout: TimeInterval,
        refresh: @escaping RefreshOperation,
        cacheSnapshot: @escaping CacheSnapshot,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) {
        self.lock = lock
        self.timeout = timeout
        self.refresh = refresh
        self.cacheSnapshot = cacheSnapshot
        self.shouldCancel = shouldCancel
    }

    /// A finished run plus, when work outlived the deadline, the task that
    /// still owns the cross-process lock.
    struct RunOutcome {
        let response: RefreshCLIResponse
        /// Non-nil only after a timeout or cancellation left the refresh in
        /// flight. The lock is released when this finishes, so a caller that
        /// intends to exit should await it — bounded — rather than rely on the
        /// kernel dropping the `flock` at process death.
        let pendingCleanup: Task<Void, Never>?
    }

    func run() async -> RunOutcome {
        switch lock.acquire() {
        case .acquired:
            break
        case let .contended(holder):
            let who = holder.map { " (\($0.shortDescription))" } ?? ""
            return settled(
                outcome: .alreadyRunning,
                duration: 0,
                outcomes: [],
                message: "Another MeterBar refresh\(who) is already running; no providers were contacted."
            )
        case let .legacyHeld(guidance):
            return settled(outcome: .alreadyRunning, duration: 0, outcomes: [], message: guidance)
        case let .unavailable(reason):
            return settled(
                outcome: .refreshFailed,
                duration: 0,
                outcomes: [],
                message: "Refresh lock unavailable: \(reason)"
            )
        }

        let startedAt = Date()
        let refreshTask = Task { await refresh() }
        let gate = RaceGate()
        let completionObserver = Task {
            await gate.offer(.completed(await refreshTask.value))
        }
        let deadlineObserver = Task {
            await gate.offer(
                await Self.watch(
                    until: startedAt.addingTimeInterval(timeout),
                    shouldCancel: shouldCancel
                )
            )
        }

        let race = await gate.wait()
        deadlineObserver.cancel()

        switch race {
        case let .completed(report):
            completionObserver.cancel()
            lock.release()
            return settled(
                outcome: outcome(for: report),
                duration: report.duration,
                outcomes: report.outcomes,
                message: message(for: report)
            )
        case .timedOut, .cancelled:
            completionObserver.cancel()
            refreshTask.cancel()

            // A cooperative provider normally ends immediately. If it does not,
            // the cross-process lock stays held until the in-flight work really
            // stops, while the bounded CLI response returns now. The handle is
            // returned rather than fired and forgotten: the caller decides how
            // long to wait for it before exiting.
            let lock = lock
            let cleanup = Task {
                _ = await refreshTask.value
                lock.release()
            }

            let timedOut = race == .timedOut
            return RunOutcome(
                response: response(
                    outcome: timedOut ? .timedOut : .cancellation,
                    duration: Date().timeIntervalSince(startedAt),
                    outcomes: [],
                    message: timedOut
                        ? "Refresh did not finish within \(Int(timeout))s; cached metrics remain available."
                        : "Refresh cancelled; cached metrics remain available."
                ),
                pendingCleanup: cleanup
            )
        }
    }

    private func outcome(for report: UsageRefreshReport) -> RefreshCLIOutcome {
        let refreshed = report.count(of: .refreshed)
        let failed = report.count(of: .failed)
        if failed == 0 { return .success }
        return refreshed > 0 ? .partialFailure : .refreshFailed
    }

    private func message(for report: UsageRefreshReport) -> String? {
        let failed = report.outcomes.filter { $0.state == .failed }
        if failed.isEmpty {
            guard report.count(of: .refreshed) == 0 else { return nil }
            return "No providers are enabled and signed in; nothing was refreshed."
        }
        let preserved = failed.filter(\.servedFromCache).count
        let names = failed.map(\.provider.displayName).sorted().joined(separator: ", ")
        return "\(failed.count) provider(s) failed to refresh (\(names)); "
            + "\(preserved) kept last-known-good metrics."
    }

    /// A run that owes the caller nothing: either the lock was never taken or
    /// it has already been released.
    private func settled(
        outcome: RefreshCLIOutcome,
        duration: TimeInterval,
        outcomes: [ProviderRefreshOutcome],
        message: String?
    ) -> RunOutcome {
        RunOutcome(
            response: response(outcome: outcome, duration: duration, outcomes: outcomes, message: message),
            pendingCleanup: nil
        )
    }

    private func response(
        outcome: RefreshCLIOutcome,
        duration: TimeInterval,
        outcomes: [ProviderRefreshOutcome],
        message: String?
    ) -> RefreshCLIResponse {
        RefreshCLIResponse(
            outcome: outcome,
            collectedAt: Date(),
            durationSeconds: duration,
            outcomes: outcomes,
            cachedMetrics: cacheSnapshot(),
            message: message
        )
    }

    private enum RaceResult: Equatable, Sendable {
        case completed(UsageRefreshReport)
        case timedOut
        case cancelled
    }

    private actor RaceGate {
        private var result: RaceResult?
        private var continuation: CheckedContinuation<RaceResult, Never>?

        func offer(_ candidate: RaceResult) {
            guard result == nil else { return }
            result = candidate
            continuation?.resume(returning: candidate)
            continuation = nil
        }

        func wait() async -> RaceResult {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private static func watch(
        until deadline: Date,
        shouldCancel: @Sendable () -> Bool
    ) async -> RaceResult {
        while Date() < deadline {
            if shouldCancel() { return .cancelled }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return .timedOut }
        }
        return .timedOut
    }
}
