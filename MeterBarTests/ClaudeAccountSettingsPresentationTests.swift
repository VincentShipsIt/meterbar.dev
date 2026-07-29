import SwiftUI
import XCTest
@testable import MeterBar

final class ClaudeAccountSettingsPresentationTests: XCTestCase {
    func testRefreshActionOwnsArrowClockwiseWithoutRequestingConfirmation() {
        let action = ClaudeAccountRowAction.refresh

        XCTAssertEqual(action.title, "Refresh")
        XCTAssertEqual(action.systemImage, "arrow.clockwise")
        XCTAssertEqual(action.route, .performRefresh)
        XCTAssertFalse(action.showsVisibleTitle)
    }

    func testReconnectActionIsVisiblyLabeledDistinctAndConfirmationGated() {
        let action = ClaudeAccountRowAction.reconnect

        XCTAssertEqual(action.title, "Reconnect")
        XCTAssertNotEqual(action.systemImage, ClaudeAccountRowAction.refresh.systemImage)
        XCTAssertEqual(action.route, .requestReconnectConfirmation)
        XCTAssertTrue(action.showsVisibleTitle)
    }

    func testReconnectConfirmationExplainsLogoutBeforeLogin() {
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "Work",
            configDirectory: "/tmp/work-claude"
        )

        XCTAssertEqual(ClaudeReconnectConfirmation.confirmButtonTitle, "Reconnect")
        XCTAssertTrue(ClaudeReconnectConfirmation.title(for: account).contains("Work"))
        XCTAssertTrue(ClaudeReconnectConfirmation.message(for: account).contains("log out"))
        XCTAssertTrue(ClaudeReconnectConfirmation.message(for: account).contains("sign in"))
    }

    func testClaudeStatusPresentationKeepsTextIconAndToneSemantic() {
        let connected = SettingsStatusPresentation.claude(.connected(.oauth), isEnabled: true)
        XCTAssertEqual(connected.text, "Connected (OAuth)")
        XCTAssertEqual(connected.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(connected.tone, .success)
        XCTAssertEqual(connected.color, MeterBarTheme.success)

        let attention = SettingsStatusPresentation.claude(.error("boom"), isEnabled: true)
        XCTAssertEqual(attention.text, "Needs Attention")
        XCTAssertNotEqual(attention.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(attention.tone, .warning)
        XCTAssertEqual(attention.color, MeterBarTheme.warning)
    }

    func testWarningStaleAndLoginRequiredStatesNeverPresentAsGreenConnected() {
        let degradedStates: [ClaudeCodeAuthState] = [
            .needsLogin,
            .stale(since: Date(timeIntervalSince1970: 1_720_000_000)),
            .error("boom")
        ]

        for state in degradedStates {
            let presentation = SettingsStatusPresentation.claude(state, isEnabled: true)
            XCTAssertNotEqual(presentation.tone, .success)
            XCTAssertNotEqual(presentation.systemImage, "checkmark.circle.fill")
            XCTAssertNotEqual(presentation.color, MeterBarTheme.success)
        }
    }

    func testDisabledAndUncheckedProfilesStayNeutral() {
        let disabled = SettingsStatusPresentation.claude(.connected(.oauth), isEnabled: false)
        XCTAssertEqual(disabled.text, "Disabled")
        XCTAssertEqual(disabled.tone, .neutral)

        let unchecked = SettingsStatusPresentation.claude(nil, isEnabled: true)
        XCTAssertEqual(unchecked.text, "Not Checked")
        XCTAssertEqual(unchecked.tone, .neutral)
    }
}
