import Foundation

/// The engine behind `meterbar wake`: a thin one-shot orchestration over the
/// same discovery, quota, runner, and ledger the app uses. It never invokes a
/// provider process or mutates anything on `dryRun`, and emits a
/// distinguishable outcome for every terminal state.
///
/// The orchestration is provider-agnostic: it drives a `WakeProviderRuntime`
/// (Claude or Codex) via `run(runtime:dryRun:limit:)`. The legacy
/// `run(provider:account:dryRun:limit:)` is retained as a Claude-only facade
/// that builds a `ClaudeWakeRuntime` and delegates to the same body — so the
/// caller that already speaks `ClaudeCodeAccount` keeps working unchanged.
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
        makeRunner: @escaping @Sendable (ClaudeCodeAccount) -> WakeExecuting = { WakeProcessRunner(account: $0) },
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

    /// Legacy Claude-only entry point. Preserved so existing callers and tests
    /// that pass a `ClaudeCodeAccount` and a provider string keep their exact
    /// behavior; a non-Claude provider string here is still a validation
    /// failure (Codex is reached through `run(runtime:)`, not this method).
    func run(provider: String, account: ClaudeCodeAccount, dryRun: Bool, limit: Int?) async -> WakeCLIResponse {
        let normalizedProvider = provider.lowercased()
        guard normalizedProvider == "claude" else {
            return .from(
                candidates: [],
                outcome: .validationFailure,
                provider: normalizedProvider,
                dryRun: dryRun,
                account: account.configDirectory,
                message: "Only the 'claude' provider is supported on this entry point."
            )
        }
        let runtime = ClaudeWakeRuntime(
            account: account,
            discovery: discovery,
            authority: authority,
            makeRunner: makeRunner
        )
        return await run(runtime: runtime, dryRun: dryRun, limit: limit)
    }

    /// Provider-agnostic one-shot wake. `dryRun` performs no subprocess and no
    /// mutation.
    func run(runtime: WakeProviderRuntime, dryRun: Bool, limit: Int?) async -> WakeCLIResponse {
        let providerToken = runtime.provider.rawValue
        let accountLabel = runtime.accountLabel

        let ledger = ledgerFactory()
        let candidates = await runtime.discover(ledger: ledger)

        // Dry-run / preview: strictly read-only. No lock, no quota fetch, no
        // subprocess, no mutation.
        if dryRun {
            return .from(
                candidates: candidates,
                outcome: .success,
                provider: providerToken,
                dryRun: true,
                account: accountLabel
            )
        }

        // Pre-flight probe only: detect a legacy watcher / another live holder
        // for a distinct, actionable message before the quota fetch — then
        // release at once. A managed app/agent watcher holds this lock for its
        // whole lifetime, so this probe excludes one-shot CLI work. If no
        // watcher owns it, the per-run runner takes the lock when launch-ready.
        // Holding this engine instance across resume() would self-contend via
        // the runner's second descriptor, so the probe is released first.
        switch lock.acquire() {
        case .acquired:
            lock.release()
        case let .contended(holder):
            let who = holder.map { " (\($0.shortDescription))" } ?? " (app or CLI)"
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: providerToken,
                dryRun: false,
                account: accountLabel,
                message: "Another Session Wake holder\(who) is already running."
            )
        case let .legacyHeld(guidance):
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: providerToken,
                dryRun: false,
                account: accountLabel,
                message: guidance
            )
        case let .unavailable(reason):
            return .from(
                candidates: candidates,
                outcome: .validationFailure,
                provider: providerToken,
                dryRun: false,
                account: accountLabel,
                message: "Session Wake lock unavailable: \(reason)"
            )
        }
        defer { lock.release() }

        // Fresh quota before any launch.
        let quota = await runtime.freshQuota()
        switch quota {
        case let .unknown(reason):
            return .from(
                candidates: candidates,
                outcome: .quotaUnknown,
                provider: providerToken,
                dryRun: false,
                account: accountLabel,
                message: reason
            )
        case let .blocked(until, reason):
            let detail = until.map { "blocked (\(reason.rawValue)) until \($0)" } ?? "blocked (\(reason.rawValue))"
            return .from(
                candidates: candidates,
                outcome: .blockedWithoutWait,
                provider: providerToken,
                dryRun: false,
                account: accountLabel,
                message: detail
            )
        case .available:
            return await resume(
                candidates: candidates,
                runner: runtime.makeRunner(),
                ledger: ledger,
                limit: limit,
                provider: providerToken,
                accountLabel: accountLabel
            )
        }
    }

    private func resume(
        candidates: [WakeSessionCandidate],
        runner: WakeExecuting,
        ledger: ReplayLedger,
        limit: Int?,
        provider: String,
        accountLabel: String?
    ) async -> WakeCLIResponse {
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
            account: accountLabel,
            summary: summary
        )
    }
}
