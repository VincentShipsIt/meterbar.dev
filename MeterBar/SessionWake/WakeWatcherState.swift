import Foundation

/// The real, user-visible states of the wake watcher.
///
/// These are deliberately distinct rather than collapsed into a single
/// "Watching" — the UI (#98) and CLI (#99) must be able to tell a caller
/// exactly why nothing is launching (waiting on reset vs quota-unknown vs
/// stopping) rather than papering over failures.
nonisolated enum WakeWatcherState: Equatable, Sendable {
    /// Feature disabled or watcher not armed.
    case off
    /// Feature on, watcher idle/armed but not currently working.
    case idle
    /// Reading transcripts to build the queue.
    case scanning
    /// Quota is blocked; waiting until `until` (nil ⇒ unknown reset).
    case waiting(until: Date?)
    /// Fresh quota could not be established; not launching.
    case quotaUnknown(reason: String)
    /// Actively resuming `sessionID`.
    case running(sessionID: String)
    /// A stop was requested; unwinding.
    case stopping
    /// The run finished; carries the outcome tally.
    case completed(summary: WakeRunSummary)
    /// The run ended abnormally.
    case failed(reason: String)
}

/// Tally of a completed (or preserved) wake run.
nonisolated struct WakeRunSummary: Equatable, Sendable {
    var resumed: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    /// Sessions still queued when the run stopped (e.g. re-exhausted quota).
    var remaining: Int = 0

    var attempted: Int { resumed + failed }
}

/// The outcome of running one session, reported by the execution layer (#97).
nonisolated enum WakeRunOutcome: Equatable, Sendable {
    case succeeded
    case failed(reason: String)
    case skipped(reason: WakeSkipReason)
    case cancelled
}

/// The execution seam the coordinator drives. #96 owns orchestration and state;
/// the concrete process runner arrives in #97. Keeping it a protocol lets the
/// state machine be tested without spawning a subprocess.
nonisolated protocol WakeExecuting: Sendable {
    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome
}
