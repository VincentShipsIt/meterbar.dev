import XCTest
import MeterBarShared
@testable import MeterBar

final class UsageLimitTests: XCTestCase {
    func testEstimatedPresentationLabelsAreExplicit() {
        let reported = UsageLimit(used: 25, total: 100, resetTime: nil)
        let estimated = UsageLimit(used: 25, total: 100, resetTime: nil, isEstimated: true)

        XCTAssertFalse(reported.isEstimated)
        XCTAssertEqual(reported.percentageText, "25%")
        XCTAssertEqual(reported.percentLeftText, "75% left")
        XCTAssertEqual(reported.usedPercentageText, "25% used")

        XCTAssertTrue(estimated.isEstimated)
        XCTAssertEqual(estimated.percentageText, "~25%")
        XCTAssertEqual(estimated.percentLeftText, "~75% left")
        XCTAssertEqual(estimated.usedPercentageText, "~25% used")
    }

    func testLegacyJSONWithoutEstimatedFlagDecodesAsReported() throws {
        let data = Data(#"{"used":25,"total":100,"resetTime":null,"windowSeconds":null}"#.utf8)
        let limit = try JSONDecoder().decode(UsageLimit.self, from: data)

        XCTAssertFalse(limit.isEstimated)
    }

    func testPercentageValues() {
        let limit = UsageLimit(used: 25, total: 100, resetTime: nil)

        XCTAssertEqual(limit.percentage, 25, accuracy: 0.01)
        XCTAssertFalse(limit.isAtLimit)
    }

    func testClampsPercentageAtBounds() {
        let overLimit = UsageLimit(used: 120, total: 100, resetTime: nil)
        let zeroTotal = UsageLimit(used: 50, total: 0, resetTime: nil)

        XCTAssertEqual(overLimit.percentage, 100, accuracy: 0.01)
        XCTAssertEqual(overLimit.rawPercentage, 120, accuracy: 0.01)
        XCTAssertTrue(overLimit.isAtLimit)

        XCTAssertEqual(zeroTotal.percentage, 0, accuracy: 0.01)
        XCTAssertFalse(zeroTotal.isAtLimit)
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

    func testUsagePaceLabelsOnPaceAndExhausted() throws {
        let now = Date(timeIntervalSince1970: 0)
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)

        let onPace = try XCTUnwrap(UsageLimit(
            used: 51,
            total: 100,
            resetTime: resetTime,
            windowSeconds: 5 * 60 * 60
        ).pace(now: now))
        XCTAssertEqual(onPace.stage, .onPace)
        XCTAssertEqual(onPace.leftLabel, "On pace")
        XCTAssertFalse(onPace.willLastToReset)

        let exhausted = try XCTUnwrap(UsageLimit(
            used: 100,
            total: 100,
            resetTime: resetTime,
            windowSeconds: 5 * 60 * 60
        ).pace(now: now))
        XCTAssertTrue(exhausted.isExhausted)
        XCTAssertEqual(exhausted.leftLabel, "Out of quota")
        XCTAssertEqual(exhausted.rightLabel(context: .weekly), "Out until reset")
    }

    func testUsagePaceRejectsInvalidOrNotYetElapsedWindows() {
        let now = Date(timeIntervalSince1970: 0)
        let validReset = now.addingTimeInterval(60)

        XCTAssertNil(UsageLimit(used: 1, total: 100, resetTime: nil, windowSeconds: 120).pace(now: now))
        XCTAssertNil(UsageLimit(used: 1, total: 100, resetTime: validReset).pace(now: now))
        XCTAssertNil(UsageLimit(used: 1, total: 100, resetTime: validReset, windowSeconds: 0).pace(now: now))
        XCTAssertNil(UsageLimit(used: 1, total: 100, resetTime: now, windowSeconds: 120).pace(now: now))
        XCTAssertNil(UsageLimit(
            used: 1,
            total: 100,
            resetTime: now.addingTimeInterval(121),
            windowSeconds: 120
        ).pace(now: now))
        XCTAssertNil(UsageLimit(
            used: 1,
            total: 100,
            resetTime: now.addingTimeInterval(120),
            windowSeconds: 120
        ).pace(now: now))
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
        let weeklyReset = UsageLimit(
            used: 25,
            total: 100,
            resetTime: now.addingTimeInterval(6 * 86_400)
        )
        let dueReset = UsageLimit(
            used: 25,
            total: 100,
            resetTime: now.addingTimeInterval(-1)
        )
        let noReset = UsageLimit(used: 25, total: 100, resetTime: nil)

        XCTAssertEqual(try XCTUnwrap(futureReset.secondsUntilReset(now: now)), 3_660, accuracy: 0.01)
        XCTAssertEqual(futureReset.resetCountdownText(now: now), "1h 1m")
        XCTAssertEqual(imminentReset.resetCountdownText(now: now), "<1m")
        XCTAssertEqual(weeklyReset.resetCountdownText(now: now), "6d")
        XCTAssertEqual(dueReset.resetCountdownText(now: now), "now")
        XCTAssertNil(noReset.resetCountdownText(now: now))
    }
}
