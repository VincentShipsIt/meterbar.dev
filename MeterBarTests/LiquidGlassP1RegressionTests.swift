import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

@MainActor
final class LiquidGlassP1RegressionTests: XCTestCase {
    // MARK: - Surface vocabulary invariants

    /// The content-layer fills must stay opaque in both appearances so cards
    /// read as solid regardless of Reduce Transparency (they are Layer 2 and
    /// never glass).
    func testContentSurfaceTokensAreOpaque() {
        assertOpaque(MeterBarTheme.Surface.content)
        assertOpaque(MeterBarTheme.Surface.inset)
    }

    /// Chrome glass collapses to this fill under Reduce Transparency; the whole
    /// point of the named token is that the fallback stays opaque.
    func testChromeReduceTransparencyFallbackIsOpaque() {
        assertOpaque(MeterBarTheme.Surface.chromeOpaqueFallback)
    }

    /// The chrome token exists as the single entry point for glass and threads
    /// the requested corner radius through to the underlying surface.
    func testChromeSurfaceTokenThreadsRadius() {
        XCTAssertEqual(MeterBarTheme.Surface.chrome(radius: 10).radius, 10)
        XCTAssertEqual(
            MeterBarTheme.Surface.chrome().radius,
            MeterBarTheme.companionShellRadius
        )
    }

    /// Resolves a SwiftUI `Color` to concrete sRGB in aqua + darkAqua and
    /// asserts it is fully opaque (alpha == 1).
    private func assertOpaque(
        _ color: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appearances = [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)]
            .compactMap { $0 }
        for appearance in appearances {
            var alpha: CGFloat = -1
            appearance.performAsCurrentDrawingAppearance {
                alpha = NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? -1
            }
            XCTAssertEqual(alpha, 1, accuracy: 0.0001, file: file, line: line)
        }
    }

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
        window.isReleasedWhenClosed = false
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
        // Fixed popover width; height is content-driven (the panel resizes to
        // fit MenuBarView on show), so assert a real frame rather than a
        // brittle fixed height that shifts as card content grows.
        XCTAssertEqual(panel.frame.width, 390, accuracy: 0.5)
        XCTAssertGreaterThan(panel.frame.height, 0)
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

    // MARK: - Liquid Glass morph tokens

    /// The glass morph + disclosure timings are shared tokens, so the swap
    /// sites can't silently drift apart. Pinning the values also documents the
    /// intended feel (smooth for glass state changes, snappy for rows).
    func testMotionTokensAreDistinctAndStable() {
        XCTAssertEqual(MeterBarTheme.Motion.standard, .smooth(duration: 0.32))
        XCTAssertEqual(MeterBarTheme.Motion.disclosure, .snappy(duration: 0.18))
        XCTAssertNotEqual(MeterBarTheme.Motion.standard, MeterBarTheme.Motion.disclosure)
    }

    // MARK: - Glass morph containers render in both states

    /// The flagship popover card swaps its exhausted (compact) and expanded
    /// bodies through a single `glassEffectID` inside a `GlassEffectContainer`.
    /// Both branches must build and lay out — a broken morph identity or an
    /// unrenderable glass surface would blank the provider card.
    func testProviderStatusCardMorphRendersBothStates() {
        let exhausted = makeSnapshot(service: .claudeCode, session: 100, weekly: 20)
        XCTAssertTrue(exhausted.hasExhaustedLimit, "session at limit should drive the compact card")
        XCTAssertGreaterThan(fittingHeight(ProviderStatusCard(snapshot: exhausted)), 0)

        let healthy = makeSnapshot(service: .claudeCode, session: 20, weekly: 20)
        XCTAssertFalse(healthy.hasExhaustedLimit, "room left should drive the expanded card")
        XCTAssertGreaterThan(fittingHeight(ProviderStatusCard(snapshot: healthy)), 0)
    }

    /// Dashboard twin: `ProviderLimitsBody` (inside `ProviderStatusCard`)
    /// blur-replaces between the blocking-reset counter and the limit rows.
    /// Both the weekly-exhausted and normal branches must render.
    func testDashboardProviderCardRendersBothLimitStates() {
        let weeklyExhausted = makeSnapshot(service: .claudeCode, session: 0, weekly: 100)
        XCTAssertTrue(weeklyExhausted.hasExhaustedWeeklyLimit)
        XCTAssertGreaterThan(
            fittingHeight(ProviderStatusCard(snapshot: weeklyExhausted, onSelect: nil)),
            0
        )

        let healthy = makeSnapshot(service: .claudeCode, session: 20, weekly: 20)
        XCTAssertFalse(healthy.hasExhaustedWeeklyLimit)
        XCTAssertGreaterThan(
            fittingHeight(ProviderStatusCard(snapshot: healthy, onSelect: nil)),
            0
        )
    }

    // MARK: - Helpers

    /// Lays a view out offscreen and returns its fitting height. A morph site
    /// that fails to build (bad glass identity, unrenderable surface) reports a
    /// zero/collapsed size or traps here.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 400)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func makeSnapshot(
        service: ServiceType,
        session: Double? = nil,
        weekly: Double? = nil
    ) -> ProviderSnapshot {
        let metrics = UsageMetrics(
            service: service,
            sessionLimit: session.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            weeklyLimit: weekly.map { UsageLimit(used: $0, total: 100, resetTime: nil) }
        )
        return ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: service,
            metrics: metrics,
            emptyDetail: ""
        )
    }
}
