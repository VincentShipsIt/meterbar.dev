import XCTest
@testable import MeterBar

final class SessionWakeNotificationDeciderTests: XCTestCase {
    private let decider = SessionWakeNotificationDecider()

    private func gates(
        global: Bool = true,
        provider: Bool = true,
        watchStart: Bool = true,
        completion: Bool = true
    ) -> SessionWakeNotificationDecider.Gates {
        SessionWakeNotificationDecider.Gates(
            notificationsEnabled: global,
            claudeProviderEnabled: provider,
            notifyOnWatchStart: watchStart,
            notifyOnCompletion: completion
        )
    }

    private let summary = SessionWakeRunSummary(resumed: 2, skipped: 1, failed: 0, finishedAt: Date())

    // MARK: All gates open

    func testWatchStartFiresWhenAllGatesOpen() {
        let fired = decider.watchStartNotification(queuedCount: 3, gates: gates())
        XCTAssertNotNil(fired)
        XCTAssertEqual(fired?.key, "session-wake-watch-start")
        XCTAssertTrue(fired?.body.contains("3 sessions") ?? false)
    }

    func testCompletionFiresWhenAllGatesOpen() {
        let fired = decider.completionNotification(summary: summary, gates: gates())
        XCTAssertNotNil(fired)
        XCTAssertEqual(fired?.key, "session-wake-completion")
        XCTAssertTrue(fired?.body.contains("Resumed 2 of 3") ?? false)
    }

    // MARK: Global gate

    func testGlobalOffSuppressesBoth() {
        XCTAssertNil(decider.watchStartNotification(queuedCount: 1, gates: gates(global: false)))
        XCTAssertNil(decider.completionNotification(summary: summary, gates: gates(global: false)))
    }

    // MARK: Provider visibility gate

    func testHiddenClaudeProviderSuppressesBoth() {
        XCTAssertNil(decider.watchStartNotification(queuedCount: 1, gates: gates(provider: false)))
        XCTAssertNil(decider.completionNotification(summary: summary, gates: gates(provider: false)))
    }

    // MARK: Per-event Session Wake gates

    func testWatchStartPreferenceGatesOnlyWatchStart() {
        XCTAssertNil(decider.watchStartNotification(queuedCount: 1, gates: gates(watchStart: false)))
        XCTAssertNotNil(decider.completionNotification(summary: summary, gates: gates(watchStart: false)))
    }

    func testCompletionPreferenceGatesOnlyCompletion() {
        XCTAssertNotNil(decider.watchStartNotification(queuedCount: 1, gates: gates(completion: false)))
        XCTAssertNil(decider.completionNotification(summary: summary, gates: gates(completion: false)))
    }

    // MARK: Copy

    func testCompletionBodyMentionsFailuresWhenPresent() {
        let failing = SessionWakeRunSummary(resumed: 1, skipped: 0, failed: 2, finishedAt: Date())
        let fired = decider.completionNotification(summary: failing, gates: gates())
        XCTAssertTrue(fired?.body.contains("2 failures") ?? false)
    }

    func testWatchStartSingularCopy() {
        let fired = decider.watchStartNotification(queuedCount: 1, gates: gates())
        XCTAssertTrue(fired?.body.contains("1 session queued") ?? false)
    }
}
