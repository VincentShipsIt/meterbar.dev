import Foundation
import XCTest
@testable import MeterBar

/// The seams the three provider scans now share instead of each carrying their
/// own copy. Every one of these used to be duplicated two or three times, so
/// the risk they guard against is silent drift: a change made in one scanner's
/// copy and not the others. Asserted here directly rather than only through a
/// full corpus scan, which would notice a divergence only as a wrong total.
final class CostScanSharedSeamTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Window seeding

    func testScanWindowsSeedsPeriodAtCutoffAndLifetimeAtDistantPast() {
        let hourlyCutoff = cutoff.addingTimeInterval(3_600)
        let before = Date()

        let windows = CostScanWindowContext.scanWindows(cutoff: cutoff, hourlyCutoff: hourlyCutoff)

        XCTAssertEqual(windows.cutoff, cutoff)
        XCTAssertEqual(windows.hourlyCutoff, hourlyCutoff)
        // `latestDate` starts at the window floor so the first event can only
        // move it forward.
        XCTAssertEqual(windows.period.latestDate, cutoff)
        XCTAssertEqual(windows.lifetime.latestDate, .distantPast)
        // `earliestDate` starts at now so the first event can only move it back.
        XCTAssertGreaterThanOrEqual(windows.period.earliestDate, before)
        XCTAssertGreaterThanOrEqual(windows.lifetime.earliestDate, before)
    }

    func testScanWindowsDefaultsHourlyCutoffToDistantPast() {
        let windows = CostScanWindowContext.scanWindows(cutoff: cutoff)

        XCTAssertEqual(windows.hourlyCutoff, .distantPast)
    }

    // MARK: - Aggregate fold

    func testFoldMergesBothWindowsWhenKeysAreDisjoint() {
        var windows = CostScanWindowContext.scanWindows(cutoff: cutoff)
        windows.lifetime.eventKeys = ["already-counted"]
        windows.lifetime.totals.input = 10
        windows.period.totals.input = 4

        var incomingPeriod = CostScanWindowContext(earliestDate: cutoff, latestDate: cutoff)
        incomingPeriod.eventKeys = ["fresh"]
        incomingPeriod.totals.input = 3
        var incomingLifetime = CostScanWindowContext(earliestDate: cutoff, latestDate: cutoff)
        incomingLifetime.eventKeys = ["fresh"]
        incomingLifetime.totals.input = 7

        XCTAssertTrue(windows.fold(period: incomingPeriod, lifetime: incomingLifetime))
        XCTAssertEqual(windows.period.totals.input, 7)
        XCTAssertEqual(windows.lifetime.totals.input, 17)
        XCTAssertEqual(windows.lifetime.eventKeys, ["already-counted", "fresh"])
    }

    /// A duplicate file — a sync conflict copy, a restored backup — carries
    /// nothing new, so it folds successfully while adding nothing.
    func testFoldSucceedsWithoutMergingWhenEveryKeyIsAlreadyCounted() {
        var windows = CostScanWindowContext.scanWindows(cutoff: cutoff)
        windows.lifetime.eventKeys = ["a", "b"]
        windows.lifetime.totals.input = 10

        var incoming = CostScanWindowContext(earliestDate: cutoff, latestDate: cutoff)
        incoming.eventKeys = ["a"]
        incoming.totals.input = 5

        XCTAssertTrue(windows.fold(period: incoming, lifetime: incoming))
        XCTAssertEqual(windows.lifetime.totals.input, 10)
        XCTAssertEqual(windows.lifetime.eventKeys, ["a", "b"])
    }

    /// The one case aggregates cannot express: a stale copy holding a prefix of
    /// the live session. The caller has to re-read it event by event.
    func testFoldRejectsPartialOverlapWithoutMutatingEitherWindow() {
        var windows = CostScanWindowContext.scanWindows(cutoff: cutoff)
        windows.lifetime.eventKeys = ["a"]
        windows.lifetime.totals.input = 10
        windows.period.totals.input = 10

        var incoming = CostScanWindowContext(earliestDate: cutoff, latestDate: cutoff)
        incoming.eventKeys = ["a", "b"]
        incoming.totals.input = 5

        XCTAssertFalse(windows.fold(period: incoming, lifetime: incoming))
        XCTAssertEqual(windows.lifetime.totals.input, 10)
        XCTAssertEqual(windows.period.totals.input, 10)
        XCTAssertEqual(windows.lifetime.eventKeys, ["a"])
    }

    /// Claude folds the same way through the same generic seam. Covered
    /// explicitly because its window type is a different shape entirely —
    /// a conformance gap would compile and silently stop merging.
    func testFoldAppliesToClaudeWindowsToo() {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: cutoff,
            hourlyCutoff: .distantPast
        )
        var incoming = ClaudeSessionTotals()
        incoming.eventKeys = ["fresh"]
        incoming.input = 6

        XCTAssertTrue(windows.fold(period: incoming, lifetime: incoming))
        XCTAssertEqual(windows.lifetime.input, 6)

        var overlapping = ClaudeSessionTotals()
        overlapping.eventKeys = ["fresh", "new"]
        overlapping.input = 9

        XCTAssertFalse(windows.fold(period: overlapping, lifetime: overlapping))
        XCTAssertEqual(windows.lifetime.input, 6)
    }

    // MARK: - Millisecond conversion

    func testMillisecondsSinceEpochRoundsToWholeMilliseconds() {
        XCTAssertEqual(CostScanValues.millisecondsSinceEpoch(0), 0)
        XCTAssertEqual(CostScanValues.millisecondsSinceEpoch(1.2345), 1_235)
        XCTAssertEqual(CostScanValues.millisecondsSinceEpoch(-1.2345), -1_235)
    }

    /// `Int(_:)` traps rather than saturating, and `isFinite` does not rule the
    /// trap out — `1e300` is finite and its millisecond value is not.
    func testMillisecondsSinceEpochRejectsValuesOutsideIntRange() {
        XCTAssertNil(CostScanValues.millisecondsSinceEpoch(1e300))
        XCTAssertNil(CostScanValues.millisecondsSinceEpoch(-1e300))
        XCTAssertNil(CostScanValues.millisecondsSinceEpoch(.infinity))
        XCTAssertNil(CostScanValues.millisecondsSinceEpoch(-.infinity))
        XCTAssertNil(CostScanValues.millisecondsSinceEpoch(.nan))
    }

    // MARK: - Dedup key

    /// Pins the exact on-the-wire format both scans emitted before they shared a
    /// builder. These strings are compared against keys already persisted in the
    /// per-file cache, so a formatting change is a silent dedup failure.
    func testDeduplicationKeyPinsTheCodexAndGrokFormats() {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000.25)

        XCTAssertEqual(
            CostScanValues.deduplicationKey(
                timestamp: timestamp,
                sessionID: "session-a",
                counts: [1, 2, 3, 4]
            ),
            "1780000000250-session-a-1-2-3-4"
        )
        XCTAssertEqual(
            CostScanValues.deduplicationKey(
                timestamp: timestamp,
                sessionID: "session-a",
                counts: [1, 2, 3, 4, 5]
            ),
            "1780000000250-session-a-1-2-3-4-5"
        )
    }

    /// Order is part of the key: reordering the counts silently stops matching
    /// previously cached events rather than failing loudly.
    func testDeduplicationKeyIsOrderSensitive() {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)

        XCTAssertNotEqual(
            CostScanValues.deduplicationKey(timestamp: timestamp, sessionID: "s", counts: [1, 2]),
            CostScanValues.deduplicationKey(timestamp: timestamp, sessionID: "s", counts: [2, 1])
        )
    }

    func testDeduplicationKeyIsNilForATimestampOutsideMillisecondRange() {
        XCTAssertNil(
            CostScanValues.deduplicationKey(
                timestamp: Date(timeIntervalSince1970: 1e300),
                sessionID: "session-a",
                counts: [1]
            )
        )
    }
}
