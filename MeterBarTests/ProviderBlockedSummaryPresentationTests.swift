import MeterBarShared
import XCTest
@testable import MeterBar

final class ProviderBlockedSummaryPresentationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func window(_ title: String, resetIn seconds: TimeInterval?, used: Double = 100) -> ResetCountdownWindow {
        ResetCountdownWindow(
            id: title,
            title: title,
            limit: UsageLimit(used: used, total: 100, resetTime: seconds.map { epoch.addingTimeInterval($0) })
        )
    }

    // MARK: - Reset phrase

    func testResolvedWindowProducesOneCountdownPhrase() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Exhausted",
            window: window("Weekly", resetIn: 3_660),
            now: epoch
        )

        XCTAssertEqual(content.statusText, "Exhausted")
        XCTAssertEqual(content.resetText, "Weekly reset in 1h 1m")
    }

    func testClockFormatIsHonoured() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Exhausted",
            window: window("Weekly", resetIn: 90_000),
            now: epoch,
            format: .clock,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )

        XCTAssertEqual(content.resetText, "Weekly reset at 01:00")
    }

    // MARK: - Redundancy suppression

    /// The bug behind "Login required ⏳ Limit exhausted Reset time unavailable":
    /// with no resolvable window there is no countdown to show, so the row must
    /// drop the hourglass entirely rather than narrate its own failure.
    func testUnresolvedWindowDropsTheCountdownEntirely() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Login required",
            window: nil,
            now: epoch
        )

        XCTAssertEqual(content.statusText, "Login required")
        XCTAssertNil(content.resetText)
    }

    func testWindowWithoutResetTimeDropsTheCountdown() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Exhausted",
            window: window("Weekly", resetIn: nil),
            now: epoch
        )

        XCTAssertNil(content.resetText)
    }

    /// An auth notice explains the block better than a stale countdown can, so it
    /// wins outright — otherwise the row says "logged out" and "resets in 3h" at
    /// once, which are contradictory instructions.
    func testAuthNoticeSuppressesTheCountdown() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Login required",
            window: window("Weekly", resetIn: 3_660),
            now: epoch,
            hasAuthNotice: true
        )

        XCTAssertEqual(content.statusText, "Login required")
        XCTAssertNil(content.resetText)
    }

    func testDueNowStillReadsAsACountdown() {
        let content = ProviderBlockedSummaryPresentation.content(
            statusText: "Exhausted",
            window: window("Session", resetIn: 0),
            now: epoch
        )

        XCTAssertEqual(content.resetText, "Session reset due now")
    }

    // MARK: - Accessibility

    func testAccessibilityLabelJoinsOnlyThePartsThatRender() {
        let blocked = ProviderBlockedSummaryPresentation.content(
            statusText: "Exhausted",
            window: window("Weekly", resetIn: 3_660),
            now: epoch
        )
        XCTAssertEqual(
            blocked.accessibilityLabel(title: "shipshitdev"),
            "shipshitdev, Exhausted, Weekly reset in 1h 1m"
        )

        let loggedOut = ProviderBlockedSummaryPresentation.content(
            statusText: "Login required",
            window: nil,
            now: epoch
        )
        XCTAssertEqual(loggedOut.accessibilityLabel(title: "shipshitdev"), "shipshitdev, Login required")
    }
}
