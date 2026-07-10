import Foundation

/// Validated numeric bounds for a wake run.
///
/// v1 is deliberately conservative: a bounded number of sessions per run,
/// per-session turn and timeout caps, and no "unlimited" default anywhere.
/// Every field is clamped into a sane range at construction so an invalid
/// preference can never widen the blast radius of automated resumes.
struct WakeBounds: Equatable, Sendable {
    /// Seconds between live quota polls while waiting.
    let pollInterval: TimeInterval
    /// Seconds to wait past a reset instant before treating quota as open.
    let bufferAfterReset: TimeInterval
    /// Seconds to pause between sequential session launches.
    let gapBetweenSessions: TimeInterval
    /// Hard wall-clock timeout for a single session launch.
    let perSessionTimeout: TimeInterval
    /// Maximum agent turns permitted per resumed session.
    let maxTurns: Int
    /// Maximum sessions resumed in one run. Never unlimited.
    let maxSessionsPerRun: Int
    /// Upper bound on consecutive quota-unknown polls before giving up, so a
    /// missing-OAuth account cannot loop forever on a stale transcript.
    let maxUnknownPolls: Int

    static let pollIntervalRange: ClosedRange<TimeInterval> = 15...900
    static let bufferRange: ClosedRange<TimeInterval> = 0...1800
    static let gapRange: ClosedRange<TimeInterval> = 0...600
    static let timeoutRange: ClosedRange<TimeInterval> = 60...21_600
    static let maxTurnsRange: ClosedRange<Int> = 1...200
    static let sessionsRange: ClosedRange<Int> = 1...100
    static let unknownPollsRange: ClosedRange<Int> = 1...240

    /// Conservative v1 defaults. Bounded sessions, not "all".
    static let `default` = WakeBounds(
        pollInterval: 60,
        bufferAfterReset: 90,
        gapBetweenSessions: 20,
        perSessionTimeout: 7200,
        maxTurns: 40,
        maxSessionsPerRun: 5,
        maxUnknownPolls: 30
    )

    init(
        pollInterval: TimeInterval,
        bufferAfterReset: TimeInterval,
        gapBetweenSessions: TimeInterval,
        perSessionTimeout: TimeInterval,
        maxTurns: Int,
        maxSessionsPerRun: Int,
        maxUnknownPolls: Int
    ) {
        self.pollInterval = pollInterval.clamped(to: WakeBounds.pollIntervalRange)
        self.bufferAfterReset = bufferAfterReset.clamped(to: WakeBounds.bufferRange)
        self.gapBetweenSessions = gapBetweenSessions.clamped(to: WakeBounds.gapRange)
        self.perSessionTimeout = perSessionTimeout.clamped(to: WakeBounds.timeoutRange)
        self.maxTurns = maxTurns.clamped(to: WakeBounds.maxTurnsRange)
        self.maxSessionsPerRun = maxSessionsPerRun.clamped(to: WakeBounds.sessionsRange)
        self.maxUnknownPolls = maxUnknownPolls.clamped(to: WakeBounds.unknownPollsRange)
    }
}

extension Comparable {
    /// Clamp a value into a closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
