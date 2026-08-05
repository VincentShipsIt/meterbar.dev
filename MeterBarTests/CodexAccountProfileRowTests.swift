import AppKit
import SwiftUI
import XCTest
@testable import MeterBar

@MainActor
final class CodexAccountProfileRowTests: XCTestCase {
    func testEnablementPublicationDoesNotOverwriteInProgressLabelEdit() {
        let previous = CodexAccount(
            id: CodexAccount.defaultID,
            name: "Default CLI Profile",
            homeDirectory: nil,
            isEnabled: true
        )
        var updated = previous
        updated.isEnabled = false
        var draft = CodexAccountProfileDraft(
            account: previous,
            resolvedHomeDirectory: "/Users/tester/.codex"
        )
        draft.name = "Personal"

        draft.reconcile(
            from: previous,
            previousResolvedHomeDirectory: "/Users/tester/.codex",
            to: updated,
            updatedResolvedHomeDirectory: "/Users/tester/.codex"
        )

        XCTAssertEqual(draft.name, "Personal")
        XCTAssertEqual(draft.homeDirectory, "/Users/tester/.codex")
    }

    func testDefaultLabelOnlySaveDoesNotPersistResolvedFallbackAsOverride() {
        let account = CodexAccount.defaultAccount
        var draft = CodexAccountProfileDraft(
            account: account,
            resolvedHomeDirectory: "/Users/tester/.codex"
        )
        draft.name = "Personal"

        XCTAssertEqual(
            draft.savePayload(for: account, resolvedHomeDirectory: "/Users/tester/.codex"),
            CodexAccountProfileSave(name: "Personal", path: nil)
        )
    }

    func testClearingDefaultDirectoryProducesExplicitClearMutation() {
        let account = CodexAccount(
            id: CodexAccount.defaultID,
            name: "Personal",
            homeDirectory: "/tmp/codex"
        )
        var draft = CodexAccountProfileDraft(account: account, resolvedHomeDirectory: "/tmp/codex")
        draft.homeDirectory = "  "

        XCTAssertEqual(
            draft.savePayload(for: account, resolvedHomeDirectory: "/tmp/codex"),
            CodexAccountProfileSave(name: "Personal", path: "")
        )

        let save = CodexAccountProfileSave(name: "Personal", path: "")
        draft.commit(save, committedResolvedHomeDirectory: "/Users/tester/.codex")

        XCTAssertNil(draft.savePayload(for: CodexAccount(
            id: CodexAccount.defaultID,
            name: "Personal",
            homeDirectory: nil
        ), resolvedHomeDirectory: "/Users/tester/.codex"))
        XCTAssertEqual(draft.homeDirectory, "/Users/tester/.codex")
    }

    func testCustomLabelOnlySaveLeavesDirectoryUnchanged() {
        let account = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        var draft = CodexAccountProfileDraft(account: account, resolvedHomeDirectory: "/tmp/codex-work")
        draft.name = "Team"

        XCTAssertEqual(
            draft.savePayload(for: account, resolvedHomeDirectory: "/tmp/codex-work"),
            CodexAccountProfileSave(name: "Team", path: nil)
        )
    }

    func testAuthenticationPresentationUsesHonestTokenStates() {
        XCTAssertEqual(CodexAccountAuthenticationState.checking.title, "Checking…")
        XCTAssertEqual(CodexAccountAuthenticationState.authenticated.title, "Connected")
        XCTAssertEqual(CodexAccountAuthenticationState.loginRequired.title, "Login required")
        XCTAssertEqual(CodexAccountAuthenticationState.disabled.title, "Disabled")
        XCTAssertTrue(
            CodexAccountAuthenticationState.authenticated.accessibilityValue.contains("usable login")
        )
        XCTAssertEqual(
            CodexAccountAuthenticationState.authenticated.statusPresentation.tone,
            .success
        )
    }

    func testAccountRowRendersWithEveryControl() {
        let account = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let view = CodexAccountSettingsRow(
            account: account,
            canDisable: true,
            canRemove: true,
            canMoveUp: false,
            canMoveDown: false,
            onEnabledChange: { _ in },
            onSave: { _, _ in },
            onRemove: {},
            onMoveUp: {},
            onMoveDown: {},
            // Zero-argument seam on purpose: the row must never store a
            // `(CodexAccount) async -> Bool`. See `CodexAccountSettingsRow.init`.
            connectionCheck: { false }
        )
        let hostingView = NSHostingView(rootView: view.frame(width: 720))

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    // MARK: - Status accessibility (issue #304)

    /// The status pill announced a label with no value, so VoiceOver read
    /// "Status for Work" and stopped — the state itself never reached the user.
    func testStatusAccessibilityAnnouncesTheConnectionStateAsItsValue() {
        XCTAssertEqual(
            ProviderAccountStatusAccessibility.label(accountName: "Work"),
            "Status for Work"
        )
        XCTAssertEqual(
            ProviderAccountStatusAccessibility.value(
                CodexAccountAuthenticationState.loginRequired.statusPresentation,
                detail: CodexAccountAuthenticationState.loginRequired.accessibilityValue
            ),
            "No usable login is available for this profile"
        )
    }

    /// Claude and Grok rows pass no richer sentence; the pill's own text is
    /// still a better value than nothing.
    func testStatusAccessibilityFallsBackToThePillTextWhenNoDetailIsSupplied() {
        XCTAssertEqual(
            ProviderAccountStatusAccessibility.value(
                CodexAccountAuthenticationState.authenticated.statusPresentation,
                detail: nil
            ),
            "Connected"
        )
    }

    func testSavePayloadHomeDirectoryAliasMatchesPath() {
        let save = ProviderAccountProfileSave(name: "Work", path: "/tmp/home")
        XCTAssertEqual(save.homeDirectory, "/tmp/home")
        XCTAssertEqual(save.path, "/tmp/home")
    }
}
