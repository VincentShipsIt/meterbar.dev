import Foundation

/// Bounds how many requests `meterbar serve` answers per second. Even a
/// loopback-only, token-gated listener can be pointed at repeatedly by a
/// misbehaving script; this keeps a single caller from turning polling into
/// an unbounded CPU/encoding cost.
nonisolated public final class ServeRateLimiter: @unchecked Sendable {
    private let maxPerSecond: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var windowStart: Date
    private var countInWindow = 0

    // The default is a closure rather than the `Date.init` reference: an
    // unapplied initializer reference is not itself `@Sendable`, so passing it
    // directly warns under Swift 6 strict concurrency.
    public init(maxPerSecond: Int, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.maxPerSecond = max(1, maxPerSecond)
        self.clock = clock
        self.windowStart = clock()
    }

    /// Sliding-by-reset (not sliding-window) counter: cheap, thread-safe, and
    /// precise enough for a bounded local endpoint.
    public func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            countInWindow = 0
        }

        guard countInWindow < maxPerSecond else { return false }
        countInWindow += 1
        return true
    }
}
