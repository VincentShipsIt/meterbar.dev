import SwiftUI
import XCTest
@testable import MeterBar

final class MeterBarThemeTests: XCTestCase {
    func testQuotaStatusColorBuckets() {
        // danger: percentLeft <= 10
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 0), MeterBarTheme.danger)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 10), MeterBarTheme.danger)
        // warning: 11...25
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 11), MeterBarTheme.warning)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 25), MeterBarTheme.warning)
        // success: > 25
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 26), MeterBarTheme.success)
        XCTAssertEqual(MeterBarTheme.quotaStatusColor(percentLeft: 100), MeterBarTheme.success)
    }

    func testAccentForEveryService() {
        XCTAssertEqual(MeterBarTheme.accent(for: .claudeCode), MeterBarTheme.claudeAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .codexCli), MeterBarTheme.codexAccent)
        XCTAssertEqual(MeterBarTheme.accent(for: .cursor), MeterBarTheme.cursorAccent)
    }

    // MARK: - Design tokens

    /// The radius scale is a strict ascending ladder — new steps must not silently
    /// duplicate or reorder existing ones.
    func testRadiusScaleIsAscending() {
        XCTAssertEqual(MeterBarTheme.Radius.small, 4)
        XCTAssertEqual(MeterBarTheme.Radius.medium, 8)
        XCTAssertEqual(MeterBarTheme.Radius.card, 12)
        XCTAssertEqual(MeterBarTheme.Radius.shell, 16)
        XCTAssertLessThan(MeterBarTheme.Radius.small, MeterBarTheme.Radius.medium)
        XCTAssertLessThan(MeterBarTheme.Radius.medium, MeterBarTheme.Radius.card)
        XCTAssertLessThan(MeterBarTheme.Radius.card, MeterBarTheme.Radius.shell)
    }

    /// The shell radius stays the single source of truth for the companion
    /// popover + detail panel.
    func testCompanionShellRadiusTracksShellToken() {
        XCTAssertEqual(MeterBarTheme.companionShellRadius, MeterBarTheme.Radius.shell)
    }

    /// The concentric rule derives nested-card radii from their container minus a
    /// spacing step, so a card reads as parallel to the surface it sits in.
    func testConcentricRadiusRule() {
        XCTAssertEqual(MeterBarTheme.Radius.concentric(outer: 16, inset: 4), 12)
        XCTAssertEqual(MeterBarTheme.Radius.concentric(outer: 12, inset: 4), 8)
        // Never returns a negative radius when the inset exceeds the outer radius.
        XCTAssertEqual(MeterBarTheme.Radius.concentric(outer: 4, inset: 8), 0)

        // Derived tokens used by the detail panel and API-usage card.
        XCTAssertEqual(MeterBarTheme.detailCardRadius, MeterBarTheme.Radius.card)
        XCTAssertEqual(MeterBarTheme.apiCardRadius, MeterBarTheme.Radius.medium)
    }

    /// The spacing scale is a 4pt grid (plus a 2pt half-step) in ascending order.
    func testSpacingScaleIsAscendingGrid() {
        let steps: [CGFloat] = [
            MeterBarTheme.Spacing.xxs,
            MeterBarTheme.Spacing.xs,
            MeterBarTheme.Spacing.sm,
            MeterBarTheme.Spacing.md,
            MeterBarTheme.Spacing.lg,
            MeterBarTheme.Spacing.xl,
            MeterBarTheme.Spacing.xxl,
        ]
        XCTAssertEqual(steps, [2, 4, 8, 12, 16, 20, 24])
        XCTAssertEqual(steps, steps.sorted(), "spacing steps must stay ascending")
    }

    /// Fill/stroke opacity tokens back the recurring tinted chips and bars; the
    /// hairline stroke must read stronger than the subtle fill.
    func testFillOpacityTokens() {
        XCTAssertEqual(MeterBarTheme.Fill.subtle, 0.14)
        XCTAssertEqual(MeterBarTheme.Fill.hairline, 0.18)
        XCTAssertGreaterThan(MeterBarTheme.Fill.hairline, MeterBarTheme.Fill.subtle)
    }

    /// Card padding is picked by surface, not by number. Every step has to land on
    /// the spacing grid — cards were being built at 11 and 14, a pixel off both
    /// the grid and each other, which is what made the popover padding look
    /// inconsistent from card to card.
    func testCardPaddingStepsSitOnTheSpacingGrid() {
        XCTAssertEqual(MeterBarTheme.CardPadding.nested.value, MeterBarTheme.Spacing.sm)
        XCTAssertEqual(MeterBarTheme.CardPadding.popover.value, MeterBarTheme.Spacing.md)
        XCTAssertEqual(MeterBarTheme.CardPadding.standard.value, MeterBarTheme.Spacing.lg)

        let grid: Set<CGFloat> = [2, 4, 8, 12, 16, 20, 24]
        for padding in MeterBarTheme.CardPadding.allCases {
            XCTAssertTrue(grid.contains(padding.value), "\(padding) is off the 4pt spacing grid")
        }
    }

    /// A tile nested inside another surface must be tighter than the surface it
    /// sits in, otherwise the two paddings stack into a visible gutter.
    func testCardPaddingTightensAsTilesNest() {
        XCTAssertLessThan(MeterBarTheme.CardPadding.nested.value, MeterBarTheme.CardPadding.popover.value)
        XCTAssertLessThan(MeterBarTheme.CardPadding.popover.value, MeterBarTheme.CardPadding.standard.value)
    }
}

/// `DashboardTile` is the single card shell, so its padding is the one place the
/// popover and the dashboard can disagree. It takes a named surface rather than a
/// number specifically so they can't.
@MainActor
final class DashboardTilePaddingTests: XCTestCase {
    func testTileDefaultsToStandardCardPadding() {
        let tile = DashboardTile { EmptyView() }

        XCTAssertEqual(tile.padding, .standard)
        XCTAssertEqual(tile.padding.value, MeterBarTheme.Spacing.lg)
    }

    func testTileRendersAtEverySurfacePadding() {
        for padding in MeterBarTheme.CardPadding.allCases {
            let tile = DashboardTile(padding: padding) {
                Text("Provider")
            }
            let host = NSHostingView(rootView: tile.frame(width: 320))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(
                host.fittingSize.height,
                padding.value * 2,
                "DashboardTile(padding: \(padding)) should lay out taller than its own insets"
            )
        }
    }
}
