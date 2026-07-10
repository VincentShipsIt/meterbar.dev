import Foundation

/// The single native watcher state machine.
///
/// Owns exactly one cancellable structured task and drives the full lifecycle:
/// scan → (wait | quota-unknown) → run → re-check → …. Fresh quota is fetched
/// before *every* launch and again after every attempt, so a session that
/// re-exhausts the window stops the queue and preserves the remaining work
/// instead of hammering a blocked account.
///
/// v1 lifetime is **app-running-only**: the watcher lives with the process.
/// There is no managed launchd helper in v1; sleep/wake and quit simply end the
/// watcher, and it is re-armed on next launch by the settings layer (#98).
actor WakeCoordinator {
    private let discovery: SessionDiscovery
    private let authority: WakeQuotaAuthority
    private let runner: WakeExecuting
    private let ledger: ReplayLedger
    private let bounds: WakeBounds
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private(set) var state: WakeWatcherState = .off
    private(set) var stateHistory: [WakeWatcherState] = []
    private var runTask: Task<Void, Never>?

    init(
        discovery: SessionDiscovery = SessionDiscovery(),
        authority: WakeQuotaAuthority = WakeQuotaAuthority(),
        runner: WakeExecuting,
        ledger: ReplayLedger = ReplayLedger(),
        bounds: WakeBounds = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.discovery = discovery
        self.authority = authority
        self.runner = runner
        self.ledger = ledger
        self.bounds = bounds
        self.now = now
        self.sleep = sleep
    }

    /// Arm the watcher for `account`. No-op if already running.
    func start(account: ClaudeCodeAccount) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runLoop(account: account)
        }
    }

    /// Cancel any in-flight watch deterministically. Cancels pending sleep/poll
    /// work; the run loop observes cancellation and returns to `off` itself (and
    /// the active child, if any, is cancelled by the runner via structured-task
    /// cancellation in #97). The loop — not `stop()` — owns the final transition
    /// so `waitUntilFinished()` reflects a settled state.
    func stop() {
        guard let task = runTask else {
            transition(.off)
            return
        }
        transition(.stopping)
        task.cancel()
    }

    /// Await the current run (test hook).
    func waitUntilFinished() async {
        await runTask?.value
    }

    // MARK: - Run loop

    /// How the loop should proceed after handling one quota decision.
    private enum LoopStep: Equatable {
        case keepGoing
        case stop
        case fail(reason: String)
    }

    private var unknownPolls = 0

    private func runLoop(account: ClaudeCodeAccount) async {
        transition(.scanning)
        let discovered = await discovery.discover(configDirectory: account.configDirectory, ledger: ledger)
        var queue = Array(discovered.filter(\.isExecutable).prefix(bounds.maxSessionsPerRun))

        var summary = WakeRunSummary()
        summary.skipped = discovered.count - queue.count
        unknownPolls = 0

        loop: while !queue.isEmpty && !Task.isCancelled {
            // Fresh quota before EVERY launch.
            let quota = await authority.freshQuota(account: account)
            let step = await handle(quota: quota, account: account, queue: &queue, summary: &summary)
            switch step {
            case .keepGoing:
                continue
            case .stop:
                break loop
            case let .fail(reason):
                summary.remaining = queue.count
                transition(.failed(reason: reason))
                runTask = nil
                return
            }
        }

        if Task.isCancelled {
            transition(.off)
        } else {
            summary.remaining = queue.count
            transition(.completed(summary: summary))
        }
        runTask = nil
    }

    private func handle(
        quota: WakeQuota,
        account: ClaudeCodeAccount,
        queue: inout [WakeSessionCandidate],
        summary: inout WakeRunSummary
    ) async -> LoopStep {
        switch quota {
        case .available:
            unknownPolls = 0
            return await launchNext(account: account, queue: &queue, summary: &summary)
        case let .blocked(until, _):
            summary.remaining = queue.count
            transition(.waiting(until: until))
            return (try? await sleepUntilRetry(until: until)) == nil ? .stop : .keepGoing
        case let .unknown(reason):
            unknownPolls += 1
            transition(.quotaUnknown(reason: reason))
            if unknownPolls >= bounds.maxUnknownPolls {
                return .fail(reason: "fresh quota unavailable after \(unknownPolls) polls")
            }
            return (try? await sleep(bounds.pollInterval)) == nil ? .stop : .keepGoing
        }
    }

    private func launchNext(
        account: ClaudeCodeAccount,
        queue: inout [WakeSessionCandidate],
        summary: inout WakeRunSummary
    ) async -> LoopStep {
        let candidate = queue.removeFirst()
        transition(.running(sessionID: candidate.sessionID))
        let outcome = await runner.run(candidate, bounds: bounds)
        await record(outcome, candidate: candidate, summary: &summary)

        guard !queue.isEmpty else { return .keepGoing }

        // Re-fetch AFTER the attempt; a re-maxed window stops the queue and
        // preserves the remaining work.
        let post = await authority.freshQuota(account: account)
        if case let .blocked(until, _) = post {
            summary.remaining = queue.count
            transition(.waiting(until: until))
            return (try? await sleepUntilRetry(until: until)) == nil ? .stop : .keepGoing
        }
        return (try? await sleep(bounds.gapBetweenSessions)) == nil ? .stop : .keepGoing
    }

    private func record(
        _ outcome: WakeRunOutcome,
        candidate: WakeSessionCandidate,
        summary: inout WakeRunSummary
    ) async {
        switch outcome {
        case .succeeded:
            summary.resumed += 1
            // Only a real resume marks the block handled, so a failed attempt
            // can be retried on a later run.
            await ledger.record(candidate.fingerprint)
        case .failed:
            summary.failed += 1
        case .skipped:
            summary.skipped += 1
        case .cancelled:
            break
        }
    }

    /// Sleep until a reset (plus buffer), or one poll interval when the reset is
    /// unknown or already elapsed. A past reset only schedules a re-check — it
    /// never proves availability.
    private func sleepUntilRetry(until: Date?) async throws {
        guard let until else {
            try await sleep(bounds.pollInterval)
            return
        }
        let target = until.addingTimeInterval(bounds.bufferAfterReset)
        let delay = target.timeIntervalSince(now())
        try await sleep(max(bounds.pollInterval, delay))
    }

    private func transition(_ next: WakeWatcherState) {
        state = next
        stateHistory.append(next)
    }
}
