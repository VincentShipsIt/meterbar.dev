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
