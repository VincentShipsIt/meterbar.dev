import AppKit
import MeterBarShared
import SwiftUI
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
        XCTAssertGreaterThan(fittingHeight(PopoverProviderStatusCard(snapshot: exhausted)), 0)

        let healthy = makeSnapshot(service: .claudeCode, session: 20, weekly: 20)
        XCTAssertFalse(healthy.hasExhaustedLimit, "room left should drive the expanded card")
        XCTAssertGreaterThan(fittingHeight(PopoverProviderStatusCard(snapshot: healthy)), 0)
    }

    /// Dashboard twin: `ProviderLimitsBody` (inside `ProviderOverviewStatusCard`)
    /// blur-replaces between the blocking-reset counter and the limit rows.
    /// Both the weekly-exhausted and normal branches must render.
    func testDashboardProviderCardRendersBothLimitStates() {
        let weeklyExhausted = makeSnapshot(service: .claudeCode, session: 0, weekly: 100)
        XCTAssertTrue(weeklyExhausted.hasExhaustedWeeklyLimit)
        XCTAssertGreaterThan(
            fittingHeight(ProviderOverviewStatusCard(snapshot: weeklyExhausted, onSelect: nil)),
            0
        )

        let healthy = makeSnapshot(service: .claudeCode, session: 20, weekly: 20)
        XCTAssertFalse(healthy.hasExhaustedWeeklyLimit)
        XCTAssertGreaterThan(
            fittingHeight(ProviderOverviewStatusCard(snapshot: healthy, onSelect: nil)),
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
