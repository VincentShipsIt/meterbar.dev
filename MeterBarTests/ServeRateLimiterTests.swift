import XCTest
@testable import MeterBar

final class ServeRateLimiterTests: XCTestCase {
    func testAllowsUpToTheConfiguredLimitWithinAWindow() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 3, clock: { now })

        XCTAssertTrue(limiter.allow())
        XCTAssertTrue(limiter.allow())
        XCTAssertTrue(limiter.allow())
        XCTAssertFalse(limiter.allow())

        now = now.addingTimeInterval(0.5)
        XCTAssertFalse(limiter.allow(), "still inside the same one-second window")
    }

    func testResetsAfterTheWindowElapses() {
        var now = Date(timeIntervalSince1970: 0)
        let limiter = ServeRateLimiter(maxPerSecond: 1, clock: { now })

        XCTAssertTrue(limiter.allow())
        XCTAssertFalse(limiter.allow())

        now = now.addingTimeInterval(1.1)
        XCTAssertTrue(limiter.allow(), "a new window should allow requests again")
    }

    func testTreatsNonPositiveLimitsAsAtLeastOne() {
        let limiter = ServeRateLimiter(maxPerSecond: 0, clock: { Date(timeIntervalSince1970: 0) })

        XCTAssertTrue(limiter.allow())
    }
}
