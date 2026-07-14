import AppKit
import MeterBarShared
import XCTest
@testable import MeterBar

@MainActor
final class LiquidGlassP1RegressionTests: XCTestCase {
    func testMenuPanelCanBecomeKey() {
        let panel = KeyableMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.canBecomeKey)
    }

    // MARK: - Menu-chrome animation regressions (smooth show/hide/resize)

    /// A status button hosted in a real window so the controller's positioning
    /// math has a non-nil `button.window` to anchor against, without depending
    /// on the live system status bar (unavailable in headless CI).
    private func makeHostedStatusButton() -> (NSWindow, NSStatusBarButton) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        window.contentView?.addSubview(button)
        return (window, button)
    }

    func testShowOrdersPanelFrontAtTargetSizeAndDismissOrdersOut() throws {
        let (window, button) = makeHostedStatusButton()
        defer { window.close() }

        var dismissCount = 0
        let controller = MeterBarMenuPanelController(
            statusButtonProvider: { button },
            onDismiss: { dismissCount += 1 }
        )
        // Deterministic end-state: no fade, orderOut happens synchronously.
        controller.motionEnabled = false

        controller.show()
        let panel = try XCTUnwrap(controller.presentedPanel)
        XCTAssertTrue(controller.isShown)
        XCTAssertTrue(panel.isVisible)
        // Default content size the panel is created with.
        XCTAssertEqual(panel.frame.width, 390, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 420, accuracy: 0.5)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)

        controller.dismiss()
        XCTAssertFalse(controller.isShown)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001, "alpha resets after fade-out")
        XCTAssertEqual(dismissCount, 1)
    }

    func testResizeUpdatesTargetFrameWhileShown() throws {
        let (window, button) = makeHostedStatusButton()
        defer { window.close() }

        let controller = MeterBarMenuPanelController(
            statusButtonProvider: { button },
            onDismiss: {}
        )
        controller.motionEnabled = false
        controller.show()
        defer { controller.dismiss() }

        let panel = try XCTUnwrap(controller.presentedPanel)
        let newSize = NSSize(width: 390, height: 260)
        controller.resize(to: newSize)

        XCTAssertEqual(panel.frame.width, newSize.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, newSize.height, accuracy: 0.5)
    }

    func testResizeIsIgnoredWhenNotShown() {
        let (window, button) = makeHostedStatusButton()
        defer { window.close() }

        let controller = MeterBarMenuPanelController(
            statusButtonProvider: { button },
            onDismiss: {}
        )
        controller.motionEnabled = false

        // Never shown: resize must not create/order a panel.
        controller.resize(to: NSSize(width: 390, height: 260))
        XCTAssertNil(controller.presentedPanel)
        XCTAssertFalse(controller.isShown)
    }

    /// Re-entrancy guard: show → dismiss → show in quick succession must not let
    /// the earlier fade-out's completion order the panel out or leave it stuck
    /// transparent after the newer show wins.
    func testRapidShowDismissShowLeavesPanelVisibleAndOpaque() throws {
        let (window, button) = makeHostedStatusButton()
        defer { window.close() }

        let controller = MeterBarMenuPanelController(
            statusButtonProvider: { button },
            onDismiss: {}
        )
        controller.motionEnabled = true // exercise the animated path + token guard

        controller.show()
        controller.dismiss()  // schedules a fade-out completion (now stale)
        controller.show()     // supersedes; must cancel the pending orderOut

        let panel = try XCTUnwrap(controller.presentedPanel)

        // Spin the main run loop past both fade durations so the stale
        // completion fires; the token guard must keep the panel on screen.
        let settle = expectation(description: "animations settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertTrue(controller.isShown)
        XCTAssertTrue(panel.isVisible, "re-show must cancel the pending fade-out orderOut")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01, "panel must not be stuck transparent")

        controller.motionEnabled = false
        controller.dismiss()
    }

    func testDailyUsageDayExposesAccessibleChartSummary() {
        let day = DailyUsageDay(
            date: Date(timeIntervalSinceReferenceDate: 0),
            segments: [
                DailyUsageProviderSegment(provider: .claudeCode, tokens: 1_200, cost: 1.25),
                DailyUsageProviderSegment(provider: .codexCli, tokens: 800, cost: 0.75),
            ],
            cost: 2
        )

        XCTAssertFalse(day.chartAccessibilityLabel.isEmpty)
        XCTAssertEqual(
            day.chartAccessibilityValue,
            "2.0K tokens, $2.00, Claude Code 1.2K tokens, $1.25, OpenAI Codex 800 tokens, $0.75"
        )
    }
}
