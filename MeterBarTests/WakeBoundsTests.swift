import XCTest
@testable import MeterBar

/// Coverage for `WakeBounds` clamping — in particular that a non-finite
/// preference (NaN or ±∞) can never survive construction and later trap in
/// `UInt64(seconds * 1e9)` when a wait is scheduled.
final class WakeBoundsTests: XCTestCase {
    // MARK: - clamped(to:) numeric guard

    func testClampedKeepsFiniteValueInsideRange() {
        XCTAssertEqual((5.0).clamped(to: 0...10), 5.0)
        XCTAssertEqual((-3.0).clamped(to: 0...10), 0.0)
        XCTAssertEqual((42.0).clamped(to: 0...10), 10.0)
        XCTAssertEqual(7.clamped(to: 1...5), 5)
    }

    func testClampedMapsNaNToLowerBound() {
        let clamped = Double.nan.clamped(to: 15...900)
        XCTAssertTrue(clamped.isFinite, "NaN must not survive clamping")
        XCTAssertEqual(clamped, 15)
    }

    func testClampedMapsInfinitiesToFiniteBounds() {
        XCTAssertEqual(Double.infinity.clamped(to: 15...900), 15)
        XCTAssertEqual((-Double.infinity).clamped(to: 15...900), 15)
    }

    // MARK: - Construction is fail-safe against non-finite input

    func testInitClampsNonFinitePreferencesToFiniteBounds() {
        let bounds = WakeBounds(
            pollInterval: .nan,
            bufferAfterReset: .infinity,
            gapBetweenSessions: -.infinity,
            perSessionTimeout: .nan,
            maxTurns: 40,
            maxSessionsPerRun: 5,
            maxUnknownPolls: 30
        )
        // Non-finite input fails safe to the narrowest (lower) bound, never
        // survives as NaN/∞ to trap later in `UInt64(seconds * 1e9)`.
        XCTAssertTrue(bounds.pollInterval.isFinite)
        XCTAssertTrue(bounds.bufferAfterReset.isFinite)
        XCTAssertTrue(bounds.gapBetweenSessions.isFinite)
        XCTAssertTrue(bounds.perSessionTimeout.isFinite)
        XCTAssertEqual(bounds.pollInterval, WakeBounds.pollIntervalRange.lowerBound)
        XCTAssertEqual(bounds.bufferAfterReset, WakeBounds.bufferRange.lowerBound)
        XCTAssertEqual(bounds.gapBetweenSessions, WakeBounds.gapRange.lowerBound)
        XCTAssertEqual(bounds.perSessionTimeout, WakeBounds.timeoutRange.lowerBound)
    }
}
