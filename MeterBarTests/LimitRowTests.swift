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

    // MARK: - Accessibility wiring (unified across densities)

    /// The unified row must apply the shared `SnapshotLimit` VoiceOver strings
    /// identically on every surface — the density only changes typography, never
    /// the spoken reading. #190 added these strings to the (now-deleted) separate
    /// rows; this guards that the reconciliation kept them on the one component.
    func testExposesCombinedAccessibilityPerDensity() {
        let limit = quotaLimit(used: 40, resetTime: future)
        for density in [LimitRow.Density.compact, .detail, .regular] {
            let row = LimitRow(limit: limit, accentColor: .blue, density: density)
            XCTAssertEqual(
                row.accessibilityLabelText,
                limit.accessibilityLabel,
                "LimitRow(\(density)) should speak the shared limit label"
            )
            XCTAssertEqual(
                row.accessibilityValueText,
                "60% left, 40% used",
                "LimitRow(\(density)) should speak left+used as one combined value"
            )
        }
    }

    /// Estimated limits append "estimated" to the label and never say a hard
    /// "Out" — the row must surface that same reading on every density.
    func testEstimatedAccessibilityReadingIsDensityIndependent() {
        let limit = quotaLimit(used: 100, isEstimated: true)
        for density in [LimitRow.Density.compact, .detail, .regular] {
            let row = LimitRow(limit: limit, accentColor: .blue, density: density)
            XCTAssertEqual(row.accessibilityLabelText, "Session, estimated")
            XCTAssertFalse(
                row.accessibilityValueText.hasPrefix("Out"),
                "estimated exhaustion must not speak a hard Out (\(density))"
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

/// Guards the single `ProviderStatusCard` shell that substitutes reset-only
/// content for the limit list without swapping to a second card design.
@MainActor
final class ProviderStatusCardSmokeTests: XCTestCase {
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
        let card = ProviderStatusCard(snapshot: snapshot(exhausted: false))
        XCTAssertFalse(card.snapshot.hasExhaustedLimit, "fixture should render the normal limit list")
        let host = NSHostingView(rootView: card.frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testExhaustedCardRendersResetOnlyContent() {
        let card = ProviderStatusCard(snapshot: snapshot(exhausted: true))
        XCTAssertTrue(card.snapshot.hasExhaustedLimit, "fixture should drive the reset-only content")
        let host = NSHostingView(rootView: card.frame(width: 360))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testOnlyAvailableCardAllowsDetailNavigation() {
        let action = {}
        let available = ProviderStatusCard(snapshot: snapshot(exhausted: false), onSelect: action)
        let exhausted = ProviderStatusCard(snapshot: snapshot(exhausted: true), onSelect: action)

        XCTAssertTrue(available.allowsDetailNavigation)
        XCTAssertFalse(exhausted.allowsDetailNavigation)
    }
}
