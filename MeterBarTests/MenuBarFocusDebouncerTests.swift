import XCTest

@testable import MeterBar

/// Covers the debounce that keeps a cmd-tab sweep from flickering the menu bar
/// through every app it passes (issue #341). Deliberately free of wall-clock
/// waits: the caller owns the timer, this type only owns the decision.
final class MenuBarFocusDebouncerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testDefaultIntervalMatchesTheDocumentedHalfSecond() {
        XCTAssertEqual(MenuBarFocusDebouncer.defaultInterval, 0.5)
    }

    func testRapidSwitchesSettleOnTheFinalApp() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.5)

        XCTAssertEqual(debouncer.record("com.apple.Terminal", at: now), now.addingTimeInterval(0.5))
        XCTAssertEqual(
            debouncer.record("com.apple.Safari", at: now.addingTimeInterval(0.1)),
            now.addingTimeInterval(0.6)
        )
        XCTAssertEqual(
            debouncer.record("com.microsoft.VSCode", at: now.addingTimeInterval(0.2)),
            now.addingTimeInterval(0.7)
        )
        // Nothing is published until the sweep stops.
        XCTAssertNil(debouncer.bundleID)

        XCTAssertTrue(debouncer.flush())
        XCTAssertEqual(debouncer.bundleID, "com.microsoft.VSCode")
        XCTAssertNil(debouncer.pendingDeadline)
    }

    func testDeadlineIsMeasuredFromTheLastActivation() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.25)

        _ = debouncer.record("com.apple.Terminal", at: now)
        _ = debouncer.record("com.apple.Safari", at: now.addingTimeInterval(2))

        XCTAssertEqual(debouncer.pendingDeadline, now.addingTimeInterval(2.25))
    }

    func testReactivatingTheSettledAppIsANoOp() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.5)
        _ = debouncer.record("com.apple.Terminal", at: now)
        XCTAssertTrue(debouncer.flush())

        XCTAssertNil(debouncer.record("com.apple.Terminal", at: now.addingTimeInterval(1)))
        XCTAssertFalse(debouncer.flush())
        XCTAssertEqual(debouncer.bundleID, "com.apple.Terminal")
    }

    func testReturningToTheSettledAppCancelsThePendingChange() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.5)
        _ = debouncer.record("com.apple.Terminal", at: now)
        XCTAssertTrue(debouncer.flush())

        _ = debouncer.record("com.apple.Safari", at: now.addingTimeInterval(1))
        XCTAssertNil(debouncer.record("com.apple.Terminal", at: now.addingTimeInterval(1.1)))

        XCTAssertNil(debouncer.pendingDeadline)
        XCTAssertFalse(debouncer.flush())
        XCTAssertEqual(debouncer.bundleID, "com.apple.Terminal")
    }

    func testFlushingWithoutAPendingChangeReportsNoChange() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.5)

        XCTAssertFalse(debouncer.flush())
        XCTAssertNil(debouncer.bundleID)
    }

    func testLosingFocusToAnUnknownAppSettlesOnNoApp() {
        var debouncer = MenuBarFocusDebouncer(interval: 0.5)
        _ = debouncer.record("com.apple.Terminal", at: now)
        XCTAssertTrue(debouncer.flush())

        XCTAssertEqual(debouncer.record(nil, at: now.addingTimeInterval(1)), now.addingTimeInterval(1.5))
        XCTAssertTrue(debouncer.flush())
        XCTAssertNil(debouncer.bundleID)
    }
}
