import Foundation

/// Coalesces a burst of app activations into one settled frontmost app.
///
/// A cmd-tab sweep activates every app it passes, and publishing each one would
/// flicker the menu bar through three providers before landing. The caller owns
/// the timer — `record` returns the deadline to schedule and `flush` commits —
/// so the whole decision stays pure and testable without wall-clock waits.
nonisolated struct MenuBarFocusDebouncer {
    // MARK: Lifecycle

    init(interval: TimeInterval = MenuBarFocusDebouncer.defaultInterval, bundleID: String? = nil) {
        self.interval = interval
        self.bundleID = bundleID
    }

    // MARK: Internal

    /// Long enough to sit out a cmd-tab sweep, short enough that switching to an
    /// app and reading the menu bar feels immediate.
    static let defaultInterval: TimeInterval = 0.5

    let interval: TimeInterval

    /// The frontmost app the menu bar is currently following.
    private(set) var bundleID: String?

    /// When the pending change becomes eligible to commit, nil when nothing is
    /// pending.
    var pendingDeadline: Date? { pending?.deadline }

    /// Records an activation.
    ///
    /// - Returns: the deadline the caller should schedule `flush()` for, or nil
    ///   when the activation changes nothing — either it names the app already
    ///   settled on, or it cancels a pending change by returning to it.
    mutating func record(_ bundleID: String?, at now: Date) -> Date? {
        guard bundleID != self.bundleID else {
            pending = nil
            return nil
        }
        let deadline = now.addingTimeInterval(interval)
        pending = Pending(bundleID: bundleID, deadline: deadline)
        return deadline
    }

    /// Commits the pending change, if any.
    ///
    /// - Returns: true when the settled app actually changed, so the caller only
    ///   republishes on a real transition.
    @discardableResult
    mutating func flush() -> Bool {
        guard let pending else { return false }
        self.pending = nil
        guard pending.bundleID != bundleID else { return false }
        bundleID = pending.bundleID
        return true
    }

    // MARK: Private

    private struct Pending {
        let bundleID: String?
        let deadline: Date
    }

    private var pending: Pending?
}
