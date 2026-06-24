import SwiftUI
import XCTest
@testable import MeterBar

final class ResetCountdownTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func limit(resetIn seconds: TimeInterval?, used: Double = 25) -> UsageLimit {
        UsageLimit(
            used: used,
            total: 100,
            resetTime: seconds.map { epoch.addingTimeInterval($0) }
        )
    }

    private func window(
        _ id: String,
        _ title: String,
        resetIn seconds: TimeInterval?,
        used: Double = 25
    ) -> ResetCountdownWindow {
        ResetCountdownWindow(id: id, title: title, limit: limit(resetIn: seconds, used: used))
    }

    // MARK: - UsageDurationText.short

    func testShortSubMinute() {
        XCTAssertEqual(UsageDurationText.short(seconds: 45), "<1m")
        XCTAssertEqual(UsageDurationText.short(seconds: 0), "<1m")
        XCTAssertEqual(UsageDurationText.short(seconds: -5), "<1m")
        XCTAssertEqual(UsageDurationText.short(seconds: 59), "<1m")
    }

    func testShortMinutesAndHours() {
        XCTAssertEqual(UsageDurationText.short(seconds: 60), "1m")
        XCTAssertEqual(UsageDurationText.short(seconds: 120), "2m")
        XCTAssertEqual(UsageDurationText.short(seconds: 3_600), "1h")
        XCTAssertEqual(UsageDurationText.short(seconds: 3_660), "1h 1m")
        XCTAssertEqual(UsageDurationText.short(seconds: 7_200), "2h")
    }

    func testShortDays() {
        XCTAssertEqual(UsageDurationText.short(seconds: 86_400), "1d")
        XCTAssertEqual(UsageDurationText.short(seconds: 90_000), "1d 1h")
        XCTAssertEqual(UsageDurationText.short(seconds: 6 * 86_400), "6d")
        XCTAssertEqual(UsageDurationText.short(seconds: 7 * 86_400), "7d")
    }

    // MARK: - ResetCountdownLabel.counterText

    func testCounterTextFutureWithAndWithoutTitle() {
        XCTAssertEqual(
            ResetCountdownLabel.counterText(title: "Weekly", limit: limit(resetIn: 3_660), now: epoch),
            "Weekly reset in 1h 1m"
        )
        XCTAssertEqual(
            ResetCountdownLabel.counterText(title: nil, limit: limit(resetIn: 3_660), now: epoch),
            "Resets in 1h 1m"
        )
    }

    func testCounterTextDueWithAndWithoutTitle() {
        XCTAssertEqual(
            ResetCountdownLabel.counterText(title: "Session", limit: limit(resetIn: -1), now: epoch),
            "Session reset due"
        )
        XCTAssertEqual(
            ResetCountdownLabel.counterText(title: nil, limit: limit(resetIn: -1), now: epoch),
            "Reset due"
        )
    }

    func testCounterTextNilWhenNoResetTime() {
        XCTAssertNil(ResetCountdownLabel.counterText(title: "Weekly", limit: limit(resetIn: nil), now: epoch))
    }

    // MARK: - NextResetCountdownLabel.selectNextWindow

    func testSelectNextWindowPicksSoonestFuture() {
        let session = window("s", "Session", resetIn: 3_600)
        let weekly = window("w", "Weekly", resetIn: 86_400)
        XCTAssertEqual(NextResetCountdownLabel.selectNextWindow([weekly, session], now: epoch)?.id, "s")
    }

    func testSelectNextWindowPrefersFutureOverPast() {
        let past = window("p", "Session", resetIn: -120)
        let future = window("f", "Weekly", resetIn: 9_000)
        XCTAssertEqual(NextResetCountdownLabel.selectNextWindow([past, future], now: epoch)?.id, "f")
    }

    func testSelectNextWindowFallsBackToMostRecentlyDueWithinGrace() {
        let justPast = window("j", "Session", resetIn: -60)
        let longPast = window("l", "Weekly", resetIn: -240)
        // Both within the 5-minute grace period: pick the least-negative (most recently due).
        XCTAssertEqual(NextResetCountdownLabel.selectNextWindow([longPast, justPast], now: epoch)?.id, "j")
    }

    func testSelectNextWindowHidesStaleWindowsBeyondGrace() {
        let stale = window("x", "Session", resetIn: -10 * 60)
        XCTAssertNil(NextResetCountdownLabel.selectNextWindow([stale], now: epoch))
    }

    func testSelectNextWindowReturnsNilWhenNoResetTimes() {
        XCTAssertNil(NextResetCountdownLabel.selectNextWindow([window("n", "Session", resetIn: nil)], now: epoch))
        XCTAssertNil(NextResetCountdownLabel.selectNextWindow([], now: epoch))
    }

    // MARK: - BlockingLimitResetCounter.selectBlockingWindow

    func testBlockingResetPicksExhaustedWeeklyOverHealthySession() {
        let session = window("s", "Session", resetIn: 3_600, used: 19)
        let weekly = window("w", "Weekly", resetIn: 4 * 86_400, used: 100)
        let sonnet = window("m", "Sonnet", resetIn: 12 * 3_600, used: 21)

        XCTAssertEqual(
            BlockingLimitResetCounter.selectBlockingWindow([session, weekly, sonnet], now: epoch)?.id,
            "w"
        )
    }

    func testBlockingResetPicksLatestFutureResetWhenMultipleLimitsAreExhausted() {
        let session = window("s", "Session", resetIn: 2 * 3_600, used: 100)
        let weekly = window("w", "Weekly", resetIn: 3 * 86_400, used: 100)

        XCTAssertEqual(BlockingLimitResetCounter.selectBlockingWindow([session, weekly], now: epoch)?.id, "w")
    }

    func testBlockingResetReturnsNilWhenExhaustedWindowHasUnknownReset() {
        let session = window("s", "Session", resetIn: 2 * 3_600, used: 100)
        let weekly = window("w", "Weekly", resetIn: nil, used: 100)

        XCTAssertNil(BlockingLimitResetCounter.selectBlockingWindow([session, weekly], now: epoch))
    }

    func testBlockingResetIgnoresHealthyWindowWithUnknownReset() {
        let session = window("s", "Session", resetIn: 2 * 3_600, used: 100)
        let weekly = window("w", "Weekly", resetIn: nil, used: 25)

        XCTAssertEqual(BlockingLimitResetCounter.selectBlockingWindow([session, weekly], now: epoch)?.id, "s")
    }

    func testBlockingResetIgnoresHealthyWindows() {
        let session = window("s", "Session", resetIn: 900, used: 25)
        let weekly = window("w", "Weekly", resetIn: 4 * 86_400, used: 80)

        XCTAssertNil(BlockingLimitResetCounter.selectBlockingWindow([session, weekly], now: epoch))
    }

    func testBlockingCounterText() {
        let weekly = window("w", "Weekly", resetIn: 90_000, used: 100)

        XCTAssertEqual(
            BlockingLimitResetCounter.titleText(for: weekly, in: [weekly]),
            "Weekly reset"
        )
        XCTAssertEqual(
            BlockingLimitResetCounter.counterText(for: weekly, now: epoch),
            "in 1d 1h"
        )
    }
}
