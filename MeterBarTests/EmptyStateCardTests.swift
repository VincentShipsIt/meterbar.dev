import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class EmptyStateCardTests: XCTestCase {
    func testToneTintUsesSemanticColors() {
        // Neutral is informational (secondary); warning routes through the shared
        // theme token. The two must be visually distinct so a "needs action"
        // state never reads like a passive "no data yet" one.
        XCTAssertEqual(EmptyStateCard.Tone.warning.tint, MeterBarTheme.warning)
        XCTAssertEqual(EmptyStateCard.Tone.neutral.tint, Color.secondary)
        XCTAssertNotEqual(EmptyStateCard.Tone.neutral.tint, EmptyStateCard.Tone.warning.tint)
    }

    func testNeutralCardWithoutActionRenders() {
        let view = EmptyStateCard(
            systemImage: "tray",
            title: "No cost data",
            message: "Enabled providers logged no local tokens in the last 30 days."
        )
        XCTAssertGreaterThan(renderedHeight(of: view), 0)
    }

    func testWarningCardWithActionRendersWithoutFiringAction() {
        var tapped = false
        let view = EmptyStateCard(
            systemImage: "exclamationmark.triangle.fill",
            title: "Not connected",
            message: "Run codex login, then Check Again.",
            tone: .warning,
            actionTitle: "Check Again",
            action: { tapped = true }
        )
        XCTAssertGreaterThan(renderedHeight(of: view), 0)
        // Building the view must never invoke the recovery action itself.
        XCTAssertFalse(tapped)
    }

    // MARK: Private

    private func renderedHeight(of view: EmptyStateCard) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 320))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
