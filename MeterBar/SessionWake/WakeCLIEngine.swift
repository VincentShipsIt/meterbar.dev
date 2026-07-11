import Foundation

/// The engine behind `meterbar wake`: a thin one-shot orchestration over the
/// same discovery, quota, runner, and ledger the app uses. It never invokes a
/// Claude process or mutates anything on `dryRun`, emits a distinguishable
/// outcome for every terminal state, and refuses non-Claude providers (Codex is
/// not exposed in v1).
struct WakeCLIEngine {
    private let discovery: SessionDiscovery
    private let authority: WakeQuotaAuthority
    private let makeRunner: @Sendable (ClaudeCodeAccount) -> WakeExecuting
    private let ledgerFactory: @Sendable () -> ReplayLedger
    private let lock: WakeLock
    private let bounds: WakeBounds
    private let shouldCancel: @Sendable () -> Bool

    init(
        discovery: SessionDiscovery = SessionDiscovery(),
        authority: WakeQuotaAuthority = WakeQuotaAuthority(),
        makeRunner: @escaping @Sendable (ClaudeCodeAccount) -> WakeExecuting,
        ledgerFactory: @escaping @Sendable () -> ReplayLedger = { ReplayLedger() },
        lock: WakeLock = WakeLock(holderKind: .cli),
        bounds: WakeBounds = .default,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) {
        self.discovery = discovery
        self.authority = authority
        self.makeRunner = makeRunner
        self.ledgerFactory = ledgerFactory
        self.lock = lock
        self.bounds = bounds
        self.shouldCancel = shouldCancel
    }

    func run(provider: String, account: ClaudeCodeAccount, dryRun: Bool, limit: Int?) async -> WakeCLIResponse {
        let normalizedProvider = provider.lowercased()
        guard normalizedProvider == "claude" else {
            // Codex is intentionally not exposed in v1.
            return .from(
                candidates: [],
                outcome: .validationFailure,
                provider: normalizedProvider,
                dryRun: dryRun,
                account: account.configDirectory,
                message: "Only the 'claude' provider is supported in this version."
            )
        }

        let ledger = ledgerFactory()
        let candidates = await discovery.discover(configDirectory: account.configDirectory, ledger: ledger)

        // Dry-run / preview: strictly read-only. No lock, no quota fetch, no
        // subprocess, no mutation.
        if dryRun {
            return .from(
                candidates: candidates,
                outcome: .success,
                provider: normalizedProvider,
                dryRun: true,
                account: account.configDirectory
            )
        }

        // Pre-flight probe only: detect a legacy watcher / another live holder
        // for a distinct, actionable message before the quota fetch — then
        // release at once. The per-run runner takes the shared lock when a
        // launch is actually ready (matching the app watcher, where the runner,
        // not the coordinator, owns the lock). Holding this engine lock across
        // resume() would self-contend: `flock` via a second descriptor in the
        // same process is denied on macOS, so every real resume would fail with
        // "another holder is active".
        switch lock.acquire() {
        case .acquired:
            lock.release()
        case let .contended(holder):
            let who = holder.map { " (\($0.shortDescription))" } ?? " (app or CLI)"
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: normalizedProvider,
                dryRun: false,
                account: account.configDirectory,
                message: "Another Session Wake holder\(who) is already running."
            )
        case let .legacyHeld(guidance):
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: normalizedProvider,
                dryRun: false,
                account: account.configDirectory,
                message: guidance
            )
        case let .unavailable(reason):
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: normalizedProvider,
                dryRun: false,
                account: account.configDirectory,
                message: "Session Wake lock unavailable: \(reason)"
            )
        }

        // Fresh quota before any launch.
        let quota = await authority.freshQuota(account: account)
        switch quota {
        case let .unknown(reason):
            return .from(
                candidates: candidates,
                outcome: .quotaUnknown,
                provider: normalizedProvider,
                dryRun: false,
                account: account.configDirectory,
                message: reason
            )
        case let .blocked(until, reason):
            let detail = until.map { "blocked (\(reason.rawValue)) until \($0)" } ?? "blocked (\(reason.rawValue))"
            return .from(
                candidates: candidates,
                outcome: .blockedWithoutWait,
                provider: normalizedProvider,
                dryRun: false,
                account: account.configDirectory,
                message: detail
            )
        case .available:
            return await resume(
                candidates: candidates,
                account: account,
                ledger: ledger,
                limit: limit,
                provider: normalizedProvider
            )
        }
    }

    private func resume(
        candidates: [WakeSessionCandidate],
        account: ClaudeCodeAccount,
        ledger: ReplayLedger,
        limit: Int?,
        provider: String
    ) async -> WakeCLIResponse {
        let runner = makeRunner(account)
        let cap = min(limit ?? bounds.maxSessionsPerRun, bounds.maxSessionsPerRun)
        let queue = Array(candidates.filter(\.isExecutable).prefix(cap))

        var summary = WakeCLIResponse.Summary()
        summary.skipped = candidates.count - candidates.filter(\.isExecutable).count
        var cancelled = false

        for candidate in queue {
            if shouldCancel() || Task.isCancelled { cancelled = true; break }
            let outcome = await runner.run(candidate, bounds: bounds)
            switch outcome {
            case .succeeded:
                summary.resumed += 1
                await ledger.record(candidate.fingerprint)
            case .failed, .permissionDenied:
                // A denial is a failure for tally purposes; the ledger is not
                // written, so the session stays retryable once the user acts.
                summary.failed += 1
            case .skipped:
                summary.skipped += 1
            case .cancelled:
                cancelled = true
            }
            if cancelled { break }
        }
        summary.remaining = max(0, queue.count - summary.resumed - summary.failed)

        let outcome: WakeCLIOutcome
        if cancelled {
            outcome = .cancellation
        } else if summary.failed > 0 {
            outcome = .partialFailure
        } else {
            outcome = .success
        }

        return .from(
            candidates: candidates,
            outcome: outcome,
            provider: provider,
            dryRun: false,
            account: account.configDirectory,
            summary: summary
        )
    }
}
