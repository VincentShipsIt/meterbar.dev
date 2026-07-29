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
            CodexAccountProfileSave(name: "Personal", homeDirectory: nil)
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
            CodexAccountProfileSave(name: "Personal", homeDirectory: "")
        )

        let save = CodexAccountProfileSave(name: "Personal", homeDirectory: "")
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
            CodexAccountProfileSave(name: "Team", homeDirectory: nil)
        )
    }

    func testAuthenticationPresentationUsesHonestTokenStates() {
        XCTAssertEqual(CodexAccountAuthenticationState.checking.title, "Checking…")
        XCTAssertEqual(CodexAccountAuthenticationState.authenticated.title, "Authenticated")
        XCTAssertEqual(CodexAccountAuthenticationState.loginRequired.title, "Login required")
        XCTAssertEqual(CodexAccountAuthenticationState.disabled.title, "Disabled")
        XCTAssertTrue(CodexAccountAuthenticationState.authenticated.accessibilityValue.contains("access token"))
    }

    func testAccountRowRendersWithEveryControl() {
        let account = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let view = CodexAccountProfileRow(
            account: account,
            canDisable: true,
            canRemove: true,
            onEnabledChange: { _ in },
            onSave: { _, _ in },
            onRemove: {},
            connectionCheck: { _ in false }
        )
        let hostingView = NSHostingView(rootView: view.frame(width: 720))

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
