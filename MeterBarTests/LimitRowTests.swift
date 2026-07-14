import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

/// Coverage for the unified `LimitRow` component that replaced the three
/// hand-drifted per-surface rows (`PopoverLimitRow`,
/// `MenuBarProviderLimitDetailRow`, `DashboardLimitRow`). The pure
/// `LimitRow.RowContent` value type carries the display logic so trailing/used
/// formatting, the "Out"/estimated rules, and currency handling can be asserted
/// directly; hosting-view smoke tests then confirm each density renders.
@MainActor
final class LimitRowTests: XCTestCase {
    private let future = Date().addingTimeInterval(3600)

    private func quotaLimit(
        used: Double,
        total: Double = 100,
        resetTime: Date? = nil,
        isEstimated: Bool = false
    ) -> SnapshotLimit {
        SnapshotLimit(
            id: "session",
            kind: .session,
            title: "Session",
            usageLimit: UsageLimit(
                used: used,
                total: total,
                resetTime: resetTime,
                windowSeconds: 3600,
                isEstimated: isEstimated
            ),
            valueStyle: .quota
        )
    }

    private func currencyLimit(used: Double, total: Double) -> SnapshotLimit {
        SnapshotLimit(
            id: "credits",
            kind: .weekly,
            title: "Credits",
            usageLimit: UsageLimit(used: used, total: total, resetTime: nil),
            valueStyle: .currency
        )
    }

    // MARK: - Trailing value

    func testQuotaTrailingShowsPercentLeftWhenHasRoom() {
        let content = LimitRow.RowContent(limit: quotaLimit(used: 40))
        XCTAssertEqual(content.trailingText, "60% left")
        XCTAssertFalse(content.isTrailingDanger)
    }

    func testQuotaTrailingShowsOutWhenExhausted() {
        let content = LimitRow.RowContent(limit: quotaLimit(used: 100))
        XCTAssertEqual(content.trailingText, "Out")
        XCTAssertTrue(content.isTrailingDanger)
    }

    func testEstimatedExhaustedShowsPercentInsteadOfOut() {
        // An estimated total must never claim a hard "Out" — the total is a
        // guess, so it falls back to the (approximate) percent-left label.
        let content = LimitRow.RowContent(limit: quotaLimit(used: 100, isEstimated: true))
        XCTAssertEqual(content.trailingText, "~0% left")
        XCTAssertNil(content.pace, "estimated limits suppress the pace overlay")
    }

    func testCurrencyTrailingAndUsedFormatAsMoney() {
        let content = LimitRow.RowContent(limit: currencyLimit(used: 3, total: 10))
        XCTAssertEqual(content.trailingText, "\(UsageFormat.cost(7)) left")
        XCTAssertEqual(content.usedText, "\(UsageFormat.cost(3)) spent")
    }

    func testQuotaUsedTextIsPercentUsed() {
        let content = LimitRow.RowContent(limit: quotaLimit(used: 40))
        XCTAssertEqual(content.usedText, "40% used")
    }

    // MARK: - Reset + estimated flags

    func testShowsResetOnlyWhenResetTimePresent() {
        XCTAssertFalse(LimitRow.RowContent(limit: quotaLimit(used: 40)).showsReset)
        XCTAssertTrue(LimitRow.RowContent(limit: quotaLimit(used: 40, resetTime: future)).showsReset)
    }

    func testShowsEstimatedTagTracksEstimatedFlag() {
        XCTAssertFalse(LimitRow.RowContent(limit: quotaLimit(used: 40)).showsEstimatedTag)
        XCTAssertTrue(LimitRow.RowContent(limit: quotaLimit(used: 40, isEstimated: true)).showsEstimatedTag)
    }

    // MARK: - Rendering smoke (every density builds)

    func testEveryDensityRenders() {
        for density in [LimitRow.Density.compact, .detail, .regular] {
            let row = LimitRow(
                limit: quotaLimit(used: 55, resetTime: future),
                accentColor: .blue,
                density: density
            )
            let host = NSHostingView(rootView: row.frame(width: 320))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(
                host.fittingSize.height,
                0,
                "LimitRow(\(density)) should produce a non-zero layout"
            )
        }
    }

    func testCurrencyRowRendersInRegularDensity() {
        let row = LimitRow(
            limit: currencyLimit(used: 3, total: 10),
            accentColor: .orange,
            density: .regular
        )
        let host = NSHostingView(rootView: row.frame(width: 320))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}

/// Guards the compact/exhausted popover swap (`PopoverProviderStatusCard`) that
/// substitutes a countdown row for the limit list — item 4 of the unification:
/// migrating the limit row must not break that card in either state.
@MainActor
final class PopoverProviderStatusCardSmokeTests: XCTestCase {
    private func snapshot(exhausted: Bool) -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: exhausted ? 100 : 40,
            total: 100,
            resetTime: Date().addingTimeInterval(exhausted ? 7200 : 3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: Date(),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    func testNormalCardRenders() {
        let card = PopoverProviderStatusCard(snapshot: snapshot(exhausted: false))
        XCTAssertFalse(card.snapshot.hasExhaustedLimit, "fixture should render the normal limit list")
        let host = NSHostingView(rootView: card.frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testExhaustedCardRendersCountdownVariant() {
        let card = PopoverProviderStatusCard(snapshot: snapshot(exhausted: true))
        XCTAssertTrue(card.snapshot.hasExhaustedLimit, "fixture should drive the compact/exhausted swap")
        let host = NSHostingView(rootView: card.frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
