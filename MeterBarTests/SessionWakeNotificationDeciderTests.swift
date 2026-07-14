import XCTest
@testable import MeterBar

/// Coverage for the Session Wake completion notification the decider emits.
///
/// The decider stays pure — it returns a `FiredWakeNotification` value (stable
/// key, composed copy) or `nil` when any gate is closed — and the app delegate
/// owns the actual `UNUserNotificationCenter` interaction. These tests pin the
/// three gates plus the pluralization / failure-count copy.
final class SessionWakeNotificationDeciderTests: XCTestCase {
    private func allowingContext(
        notifyOnCompletion: Bool = true,
        providerDisplayName: String = "Claude Code"
    ) -> SessionWakeNotificationContext {
        SessionWakeNotificationContext(
            globalNotificationsEnabled: true,
            providerEnabled: true,
            providerDisplayName: providerDisplayName,
            notifyOnCompletion: notifyOnCompletion
        )
    }

    func testCompletionSuppressedWhenAnyGateClosed() {
        let summary = WakeRunSummary(resumed: 1)
        let closed = [
            SessionWakeNotificationContext(
                globalNotificationsEnabled: false, providerEnabled: true,
                providerDisplayName: "Claude Code", notifyOnCompletion: true
            ),
            SessionWakeNotificationContext(
                globalNotificationsEnabled: true, providerEnabled: false,
                providerDisplayName: "Claude Code", notifyOnCompletion: true
            ),
            SessionWakeNotificationContext(
                globalNotificationsEnabled: true, providerEnabled: true,
                providerDisplayName: "Claude Code", notifyOnCompletion: false
            )
        ]
        for context in closed {
            XCTAssertNil(SessionWakeNotificationDecider.completionNotification(summary: summary, context: context))
        }
    }

    func testIdlePassSummaryIsSuppressed() {
        // The continuous watcher ends every rescan pass in .completed; an idle
        // pass (nothing attempted, nothing queued) must not post "0 of 0".
        let fired = SessionWakeNotificationDecider.completionNotification(
            summary: WakeRunSummary(),
            context: allowingContext()
        )
        XCTAssertNil(fired)
    }

    func testRequeuedOnlySummaryStillNotifies() {
        // Quota re-exhausted before anything launched: attempted 0 but work
        // remains queued — that is worth telling the user about.
        let fired = SessionWakeNotificationDecider.completionNotification(
            summary: WakeRunSummary(remaining: 2),
            context: allowingContext()
        )
        XCTAssertEqual(fired?.body, "Resumed 0 of 0 Claude Code sessions. 2 still queued.")
    }

    func testCompletionSingularCopy() {
        let summary = WakeRunSummary(resumed: 1)
        let fired = SessionWakeNotificationDecider.completionNotification(summary: summary, context: allowingContext())
        XCTAssertEqual(fired?.key, "session-wake-completion")
        XCTAssertEqual(fired?.title, "Session Wake — Run Complete")
        XCTAssertEqual(fired?.body, "Resumed 1 of 1 Claude Code session.")
    }

    func testCompletionPluralWithSingleFailure() {
        // resumed 2 + failed 1 ⇒ attempted 3.
        let summary = WakeRunSummary(resumed: 2, failed: 1)
        let fired = SessionWakeNotificationDecider.completionNotification(summary: summary, context: allowingContext())
        XCTAssertEqual(fired?.body, "Resumed 2 of 3 Claude Code sessions. 1 failure.")
    }

    func testCompletionPluralFailures() {
        let summary = WakeRunSummary(resumed: 0, failed: 2)
        let fired = SessionWakeNotificationDecider.completionNotification(summary: summary, context: allowingContext())
        XCTAssertEqual(fired?.body, "Resumed 0 of 2 Claude Code sessions. 2 failures.")
    }

    func testCompletionMentionsRemainingWhenRequeued() {
        // Quota re-exhausted mid-run: some resumed, some still queued.
        let summary = WakeRunSummary(resumed: 1, failed: 0, skipped: 0, remaining: 2)
        let fired = SessionWakeNotificationDecider.completionNotification(summary: summary, context: allowingContext())
        XCTAssertEqual(fired?.body, "Resumed 1 of 1 Claude Code session. 2 still queued.")
    }

    func testCompletionCopyUsesProviderDisplayName() {
        // Codex runs surface the Codex provider name, not a hardcoded "Claude".
        let summary = WakeRunSummary(resumed: 2, failed: 1)
        let fired = SessionWakeNotificationDecider.completionNotification(
            summary: summary,
            context: allowingContext(providerDisplayName: "Codex")
        )
        XCTAssertEqual(fired?.body, "Resumed 2 of 3 Codex sessions. 1 failure.")
    }

    func testCompletionKeyIsStableAcrossDifferentCounts() {
        // A stable key means re-posting replaces the banner rather than stacking.
        let first = SessionWakeNotificationDecider.completionNotification(
            summary: WakeRunSummary(resumed: 1), context: allowingContext()
        )
        let second = SessionWakeNotificationDecider.completionNotification(
            summary: WakeRunSummary(resumed: 5, failed: 3), context: allowingContext()
        )
        XCTAssertEqual(first?.key, second?.key)
    }
}
