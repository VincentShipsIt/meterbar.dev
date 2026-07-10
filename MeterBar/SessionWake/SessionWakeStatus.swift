import Foundation

// MARK: - SessionWakeTone

/// Semantic tone for a wake status, mapped to concrete adaptive colors at the
/// view layer (so this model stays free of SwiftUI and unit-testable). Keeping
/// the palette choice out of the enum lets light/dark appearances resolve the
/// actual `Color` through `MeterBarTheme`.
enum SessionWakeTone: Equatable, Sendable {
    case neutral
    case active
    case waiting
    case warning
    case danger
    case success
}

// MARK: - SessionWakeStatus

/// The user-facing lifecycle of the Session Wake watcher.
///
/// These are **presentation** states, deliberately distinct from the automation
/// core's quota gate (`WakeQuotaState` from #96) and runner outcomes (#97). The
/// shared coordinator seam maps its internal state into exactly one of these so
/// the Settings pane and the menu-bar popover render from one vocabulary and no
/// real state is collapsed into a single "Watching" label (issue #98).
enum SessionWakeStatus: Equatable, Sendable {
    /// Feature disabled entirely — no discovery, no polling, no resume.
    case off
    /// Feature enabled but the watcher is not armed. Read-only Preview is still
    /// permitted; nothing runs in the background.
    case idle
    /// Watcher armed and between cycles, waiting for the next scan/poll tick.
    case armed
    /// Actively discovering blocked sessions for the selected account.
    case scanning
    /// Quota is blocked; the watcher is counting down to the reset window.
    /// `until` is nil when the reset instant itself is unknown (conservative
    /// re-poll). `blockedCount` is how many sessions are queued.
    case waiting(until: Date?, blockedCount: Int)
    /// Fresh quota could not prove availability; the gate fails closed and
    /// nothing launches. `reason` is a short, already-humanized explanation.
    case quotaUnknown(reason: String)
    /// Resuming sessions sequentially. `completed` of `total` finished so far.
    case running(completed: Int, total: Int)
    /// The user disarmed mid-run; the active attempt is being cancelled.
    case stopping
    /// The most recent run finished. The count summary lives in the
    /// coordinator's `lastRun`; this state just marks the transient terminal.
    case completed
    /// A failure the user should see (e.g. selected account removed, runner
    /// error). `message` is a short, user-facing sentence.
    case needsAttention(String)

    /// Whether the watcher is engaged in any background activity. Drives the
    /// menu-bar activity affordance and prevents "Off/Idle" from looking busy.
    var isWatcherActive: Bool {
        switch self {
        case .armed, .scanning, .waiting, .running, .stopping:
            return true
        case .off, .idle, .quotaUnknown, .completed, .needsAttention:
            return false
        }
    }

    /// Short chip label shown in both surfaces.
    var label: String {
        switch self {
        case .off: return "Off"
        case .idle: return "Idle"
        case .armed: return "Armed"
        case .scanning: return "Scanning"
        case .waiting: return "Waiting"
        case .quotaUnknown: return "Quota Unknown"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .needsAttention: return "Needs Attention"
        }
    }

    /// One-line detail beneath the label; nil when the label is self-sufficient.
    var detail: String? {
        switch self {
        case .off:
            return "Session Wake is disabled."
        case .idle:
            return "Enabled — watcher off. Preview is available."
        case .armed:
            return "Waiting for the next scan."
        case .scanning:
            return "Looking for blocked sessions."
        case let .waiting(_, blockedCount):
            let noun = blockedCount == 1 ? "session" : "sessions"
            return "\(blockedCount) \(noun) waiting for quota reset."
        case let .quotaUnknown(reason):
            return reason
        case let .running(completed, total):
            return "Resuming \(completed) of \(total)."
        case .stopping:
            return "Stopping the watcher."
        case .completed:
            return "Last run finished."
        case let .needsAttention(message):
            return message
        }
    }

    /// SF Symbol representing the state.
    var systemImage: String {
        switch self {
        case .off: return "moon.zzz"
        case .idle: return "pause.circle"
        case .armed: return "dot.radiowaves.left.and.right"
        case .scanning: return "magnifyingglass"
        case .waiting: return "clock"
        case .quotaUnknown: return "questionmark.circle"
        case .running: return "play.circle"
        case .stopping: return "stop.circle"
        case .completed: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.triangle"
        }
    }

    var tone: SessionWakeTone {
        switch self {
        case .off, .idle: return .neutral
        case .armed, .scanning, .running: return .active
        case .waiting: return .waiting
        case .quotaUnknown: return .warning
        case .stopping: return .warning
        case .completed: return .success
        case .needsAttention: return .danger
        }
    }
}

// MARK: - SessionWakeRunSummary

/// The result of one completed wake run, derived from the runner's structured
/// outcomes (#97). Counts are display-truth: they mirror the runner rather than
/// re-deriving anything, so "Completion counts match structured runner
/// outcomes" (issue #98) holds by construction.
struct SessionWakeRunSummary: Equatable, Sendable, Codable {
    let resumed: Int
    let skipped: Int
    let failed: Int
    let finishedAt: Date

    var attempted: Int { resumed + skipped + failed }

    /// Compact "2 resumed · 1 skipped · 0 failed" summary line.
    var countsLine: String {
        "\(resumed) resumed · \(skipped) skipped · \(failed) failed"
    }
}

// MARK: - SessionWakeEligibility

/// A single class of skipped session with its count, e.g. "dead worktree: 2".
struct SessionWakeSkip: Equatable, Sendable {
    let reason: String
    let count: Int
}

/// The read-only Preview result: how many sessions are eligible to resume and
/// why others are skipped. Produced without any subprocess or filesystem
/// mutation (dry-run invariant, epic #94).
struct SessionWakeEligibility: Equatable, Sendable {
    /// Sessions that would be resumed if quota were available.
    let eligibleCount: Int
    /// Per-reason breakdown of sessions that would be skipped.
    let skips: [SessionWakeSkip]
    /// Optional advisory shown when discovery is unavailable in this build
    /// (interim, until the #95 discovery layer is wired to the coordinator).
    let note: String?

    init(eligibleCount: Int, skips: [SessionWakeSkip] = [], note: String? = nil) {
        self.eligibleCount = eligibleCount
        self.skips = skips
        self.note = note
    }

    var skippedCount: Int {
        skips.reduce(0) { $0 + $1.count }
    }
}
