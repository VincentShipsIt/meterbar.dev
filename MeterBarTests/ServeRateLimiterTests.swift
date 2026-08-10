import XCTest
@testable import MeterBar

final class ServeRateLimiterTests: XCTestCase {
    private let source = "127.0.0.1"

    func testAllowsUpToTheConfiguredLimitWithinAWindow() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 3, clock: { now })

        XCTAssertTrue(limiter.allow(source: source))
        XCTAssertTrue(limiter.allow(source: source))
        XCTAssertTrue(limiter.allow(source: source))
        XCTAssertFalse(limiter.allow(source: source))

        now = now.addingTimeInterval(0.5)
        XCTAssertFalse(limiter.allow(source: source), "still inside the same one-second window")
    }

    func testResetsAfterTheWindowElapses() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 1, clock: { now })

        XCTAssertTrue(limiter.allow(source: source))
        XCTAssertFalse(limiter.allow(source: source))

        now = now.addingTimeInterval(1.1)
        XCTAssertTrue(limiter.allow(source: source), "a new window should allow requests again")
    }

    func testTreatsNonPositiveLimitsAsAtLeastOne() {
        let limiter = ServeRateLimiter(maxPerSecond: 0, clock: { Date(timeIntervalSince1970: 0) })

        XCTAssertTrue(limiter.allow(source: source))
    }

    // MARK: Per-source isolation

    /// The whole point of keying by source: one caller exhausting its window
    /// must not spend anybody else's budget. A single global window let one
    /// unauthenticated LAN host keep `meterbar serve --allow-remote` at 429 for
    /// the legitimate token holder.
    func testOneSourceExhaustingItsWindowDoesNotSpendAnother() {
        let now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 2, clock: { now })

        XCTAssertTrue(limiter.allow(source: "192.168.1.50"))
        XCTAssertTrue(limiter.allow(source: "192.168.1.50"))
        XCTAssertFalse(limiter.allow(source: "192.168.1.50"))

        XCTAssertTrue(limiter.allow(source: "127.0.0.1"), "a burst from one address consumed another's budget")
        XCTAssertTrue(limiter.allow(source: "127.0.0.1"))
        XCTAssertFalse(limiter.allow(source: "127.0.0.1"), "each source still gets exactly its own cap")
    }

    // MARK: Table bounding

    /// Per-source buckets must not become an unbounded, remotely growable map.
    /// Sources whose window has elapsed are dropped once the table is full.
    func testDropsElapsedSourcesInsteadOfGrowingTheTableWithoutBound() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 1, maxTrackedSources: 4, clock: { now })

        for index in 0..<4 {
            XCTAssertTrue(limiter.allow(source: "10.0.0.\(index)"))
        }
        XCTAssertEqual(limiter.trackedSourceCount, 4)

        now = now.addingTimeInterval(1.1)
        XCTAssertTrue(limiter.allow(source: "10.0.0.99"))
        XCTAssertLessThanOrEqual(limiter.trackedSourceCount, 4, "the source table grew past its bound")
    }

    /// With every tracked window still live, admitting a new source has to
    /// evict an existing one. Eviction only ever hands budget back, so it can
    /// never be used to starve the caller that gets dropped.
    func testEvictsTheOldestLiveSourceWhenTheTableIsFull() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 1, maxTrackedSources: 2, clock: { now })

        XCTAssertTrue(limiter.allow(source: "10.0.0.1"))
        now = now.addingTimeInterval(0.1)
        XCTAssertTrue(limiter.allow(source: "10.0.0.2"))
        now = now.addingTimeInterval(0.1)

        XCTAssertTrue(limiter.allow(source: "10.0.0.3"), "a new source must still be admitted")
        XCTAssertLessThanOrEqual(limiter.trackedSourceCount, 2)
        XCTAssertFalse(limiter.allow(source: "10.0.0.3"), "the newest source still carries its own cap")
    }
}
