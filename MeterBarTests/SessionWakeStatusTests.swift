import XCTest
@testable import MeterBar

final class SessionWakeStatusTests: XCTestCase {
    func testDistinctStatesAreNotCollapsed() {
        // Every state the issue enumerates must have a distinct label so the UI
        // never collapses "Running / Stopping / Quota Unknown" into "Watching".
        let states: [SessionWakeStatus] = [
            .off,
            .idle,
            .armed,
            .scanning,
            .waiting(until: nil, blockedCount: 3),
            .quotaUnknown(reason: "Not authenticated"),
            .running(completed: 1, total: 4),
            .stopping,
            .completed,
            .needsAttention("Account removed")
        ]
        let labels = Set(states.map(\.label))
        XCTAssertEqual(labels.count, states.count, "Each state must render a unique label.")
    }

    func testWatcherActiveOnlyForEngagedStates() {
        XCTAssertFalse(SessionWakeStatus.off.isWatcherActive)
        XCTAssertFalse(SessionWakeStatus.idle.isWatcherActive)
        XCTAssertTrue(SessionWakeStatus.armed.isWatcherActive)
        XCTAssertTrue(SessionWakeStatus.scanning.isWatcherActive)
        XCTAssertTrue(SessionWakeStatus.waiting(until: nil, blockedCount: 0).isWatcherActive)
        XCTAssertTrue(SessionWakeStatus.running(completed: 0, total: 1).isWatcherActive)
        XCTAssertTrue(SessionWakeStatus.stopping.isWatcherActive)
        XCTAssertFalse(SessionWakeStatus.quotaUnknown(reason: "x").isWatcherActive)
        XCTAssertFalse(SessionWakeStatus.completed.isWatcherActive)
        XCTAssertFalse(SessionWakeStatus.needsAttention("x").isWatcherActive)
    }

    func testWaitingDetailPluralizes() {
        XCTAssertEqual(
            SessionWakeStatus.waiting(until: nil, blockedCount: 1).detail,
            "1 session waiting for quota reset."
        )
        XCTAssertEqual(
            SessionWakeStatus.waiting(until: nil, blockedCount: 2).detail,
            "2 sessions waiting for quota reset."
        )
    }

    func testTonesMapToSeverity() {
        XCTAssertEqual(SessionWakeStatus.off.tone, .neutral)
        XCTAssertEqual(SessionWakeStatus.running(completed: 0, total: 1).tone, .active)
        XCTAssertEqual(SessionWakeStatus.waiting(until: nil, blockedCount: 0).tone, .waiting)
        XCTAssertEqual(SessionWakeStatus.quotaUnknown(reason: "x").tone, .warning)
        XCTAssertEqual(SessionWakeStatus.completed.tone, .success)
        XCTAssertEqual(SessionWakeStatus.needsAttention("x").tone, .danger)
    }

    func testRunSummaryCounts() {
        let summary = SessionWakeRunSummary(resumed: 2, skipped: 1, failed: 1, finishedAt: Date())
        XCTAssertEqual(summary.attempted, 4)
        XCTAssertEqual(summary.countsLine, "2 resumed · 1 skipped · 1 failed")
    }

    func testEligibilitySkippedCount() {
        let eligibility = SessionWakeEligibility(
            eligibleCount: 3,
            skips: [
                SessionWakeSkip(reason: "dead worktree", count: 2),
                SessionWakeSkip(reason: "subagent", count: 1)
            ]
        )
        XCTAssertEqual(eligibility.skippedCount, 3)
    }
}
