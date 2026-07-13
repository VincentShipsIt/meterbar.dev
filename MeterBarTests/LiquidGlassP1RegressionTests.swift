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
