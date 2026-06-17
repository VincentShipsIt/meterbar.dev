import XCTest
@testable import MeterBar

final class UsageLimitTests: XCTestCase {
    func testPercentageAndRemainingValues() {
        let limit = UsageLimit(used: 25, total: 100, resetTime: nil)

        XCTAssertEqual(limit.percentage, 25, accuracy: 0.01)
        XCTAssertEqual(limit.remaining, 75, accuracy: 0.01)
        XCTAssertFalse(limit.isNearLimit)
        XCTAssertFalse(limit.isAtLimit)
        XCTAssertEqual(limit.statusColor, .good)
    }

    func testClampsPercentageAtBounds() {
        let overLimit = UsageLimit(used: 120, total: 100, resetTime: nil)
        let zeroTotal = UsageLimit(used: 50, total: 0, resetTime: nil)

        XCTAssertEqual(overLimit.percentage, 100, accuracy: 0.01)
        XCTAssertEqual(overLimit.remaining, 0, accuracy: 0.01)
        XCTAssertTrue(overLimit.isAtLimit)
        XCTAssertEqual(overLimit.statusColor, .critical)

        XCTAssertEqual(zeroTotal.percentage, 0, accuracy: 0.01)
        XCTAssertEqual(zeroTotal.remaining, 0, accuracy: 0.01)
        XCTAssertFalse(zeroTotal.isNearLimit)
        XCTAssertEqual(zeroTotal.statusColor, .good)
    }

    func testWarningThreshold() {
        let nearLimit = UsageLimit(used: 85, total: 100, resetTime: nil)

        XCTAssertTrue(nearLimit.isNearLimit)
        XCTAssertFalse(nearLimit.isAtLimit)
        XCTAssertEqual(nearLimit.statusColor, .warning)
    }

    func testUsagePaceLabelsReserveAndDeficit() {
        let now = Date(timeIntervalSince1970: 0)
        let halfWindowRemaining = now.addingTimeInterval(2.5 * 60 * 60)

        let reserveLimit = UsageLimit(
            used: 40,
            total: 100,
            resetTime: halfWindowRemaining,
            windowSeconds: 5 * 60 * 60
        )
        let reservePace = reserveLimit.pace(now: now)

        XCTAssertEqual(reservePace?.stage, .reserve)
        XCTAssertEqual(reservePace?.leftLabel, "10% in reserve")
        XCTAssertEqual(reservePace?.rightLabel(), "Lasts until reset")

        let deficitLimit = UsageLimit(
            used: 75,
            total: 100,
            resetTime: halfWindowRemaining,
            windowSeconds: 5 * 60 * 60
        )
        let deficitPace = deficitLimit.pace(now: now)

        XCTAssertEqual(deficitPace?.stage, .deficit)
        XCTAssertEqual(deficitPace?.leftLabel, "25% in deficit")
        XCTAssertEqual(deficitPace?.rightLabel(), "Projected empty in 50m")
    }

    func testResetCountdownText() throws {
        let now = Date(timeIntervalSince1970: 0)
        let futureReset = UsageLimit(
            used: 25,
            total: 100,
            resetTime: now.addingTimeInterval(3_660)
        )
        let imminentReset = UsageLimit(
            used: 25,
            total: 100,
            resetTime: now.addingTimeInterval(45)
        )
        let dueReset = UsageLimit(
            used: 25,
            total: 100,
            resetTime: now.addingTimeInterval(-1)
        )
        let noReset = UsageLimit(used: 25, total: 100, resetTime: nil)

        XCTAssertEqual(try XCTUnwrap(futureReset.secondsUntilReset(now: now)), 3_660, accuracy: 0.01)
        XCTAssertEqual(futureReset.resetCountdownText(now: now), "1h 1m")
        XCTAssertEqual(imminentReset.resetCountdownText(now: now), "1m")
        XCTAssertEqual(dueReset.resetCountdownText(now: now), "now")
        XCTAssertNil(noReset.resetCountdownText(now: now))
    }
}
