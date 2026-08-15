import Foundation

/// The cooperative cancellation flag shared by every long-running `meterbar`
/// command.
///
/// The shape is always the same: a signal handler running off the command's
/// task flips the flag, and the command hands the engine a
/// `@Sendable () -> Bool` that reads it. `Task.isCancelled` cannot serve —
/// a `DispatchSource` event handler is not running inside the command's task,
/// so the task's own cancellation state never changes.
///
/// `serve`, `guard`, `refresh`, `wake`, and `wake-agent` each carried a private
/// copy of this class, and the copies had already drifted (one used
/// `withLock`, the rest hand-rolled `lock()`/`unlock()`).
nonisolated public final class CLICancellationFlag: @unchecked Sendable {
    /// Guards `cancelled`: the flag is written from a signal-source handler on
    /// a global queue and read from the command's async engine.
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }
}
