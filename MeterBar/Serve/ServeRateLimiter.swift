import Foundation

/// Bounds how many requests `meterbar serve` answers per second, **per source
/// address**. Even a loopback-only, token-gated listener can be pointed at
/// repeatedly by a misbehaving script; this keeps a single caller from turning
/// polling into an unbounded CPU/encoding cost.
///
/// The budget is per source rather than process-wide because the limit is
/// charged before a request is parsed or authenticated: with `--allow-remote`,
/// one global window would let any unauthenticated device on the LAN keep the
/// listener saturated and hold the token holder at `429` indefinitely. Keying
/// by source bounds what an invalid request costs to the source that sent it.
nonisolated public final class ServeRateLimiter: @unchecked Sendable {
    /// How many distinct sources carry their own window before the table starts
    /// evicting. Bounds the memory a remote caller can make the server hold:
    /// each entry is a date and a count, so 1024 sources is a few tens of KB.
    public static let defaultMaxTrackedSources = 1_024

    private struct Window {
        var start: Date
        var count: Int
    }

    private let maxPerSecond: Int
    private let maxTrackedSources: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var windows: [String: Window] = [:]

    // The default is a closure rather than the `Date.init` reference: an
    // unapplied initializer reference is not itself `@Sendable`, so passing it
    // directly warns under Swift 6 strict concurrency.
    public init(
        maxPerSecond: Int,
        maxTrackedSources: Int = ServeRateLimiter.defaultMaxTrackedSources,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxPerSecond = max(1, maxPerSecond)
        self.maxTrackedSources = max(1, maxTrackedSources)
        self.clock = clock
    }

    /// Number of sources currently holding a window. Exposed for tests that
    /// assert the table stays bounded.
    public var trackedSourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return windows.count
    }

    /// Sliding-by-reset (not sliding-window) counter per source: cheap,
    /// thread-safe, and precise enough for a bounded local endpoint.
    public func allow(source: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        var window = windows[source] ?? Window(start: now, count: 0)
        if now.timeIntervalSince(window.start) >= 1 {
            window = Window(start: now, count: 0)
        }

        guard window.count < maxPerSecond else {
            windows[source] = window
            return false
        }

        window.count += 1
        if windows[source] == nil {
            makeRoomForANewSource(now: now)
        }
        windows[source] = window
        return true
    }

    /// Eviction fails open: dropping a window only ever hands its source a
    /// fresh budget, so a caller that floods the table with new addresses can
    /// never use eviction to starve anyone. Elapsed windows go first — they are
    /// already spent — and only then the least recently started live one.
    private func makeRoomForANewSource(now: Date) {
        guard windows.count >= maxTrackedSources else { return }

        windows = windows.filter { now.timeIntervalSince($0.value.start) < 1 }
        while windows.count >= maxTrackedSources {
            guard let oldest = windows.min(by: { $0.value.start < $1.value.start })?.key else { return }
            windows.removeValue(forKey: oldest)
        }
    }
}
