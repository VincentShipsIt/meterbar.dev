import AppKit
import MeterBarShared
import SwiftUI
import XCTest
@testable import MeterBar

final class MenuBarDetailPanelLayoutTests: XCTestCase {
    // A 1512x950 visible frame with the popover anchored near the top right,
    // mirroring the real menu-bar panel placement (AppKit bottom-left origin).
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let anchorFrame = CGRect(x: 1100, y: 300, width: 390, height: 600)

    func testHoverPolicyDismissesOnlyAfterLeavingBothPanels() {
        XCTAssertFalse(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: true,
            detailIsHovered: false
        ))
        XCTAssertFalse(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: false,
            detailIsHovered: true
        ))
        XCTAssertTrue(MeterBarMenuDetailHoverPolicy.shouldDismiss(
            sourceIsHovered: false,
            detailIsHovered: false
        ))
    }

    func testDefaultAlignsPanelTopToAnchorTop() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400
        )

        XCTAssertEqual(frame.maxY, anchorFrame.maxY)
        XCTAssertEqual(frame.height, 400)
    }

    func testPanelIsPlacedLeftOfAnchorWithGap() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400
        )

        XCTAssertEqual(frame.width, MeterBarMenuDetailPanelLayout.detailWidth)
        XCTAssertEqual(
            frame.maxX,
            anchorFrame.minX - MeterBarMenuDetailPanelLayout.panelGap
        )
    }

    func testPreferredTopAlignsPanelTopToClickedCard() {
        // A provider card whose top sits 280pt below the popover top.
        let cardTopY = anchorFrame.maxY - 280

        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: cardTopY
        )

        XCTAssertEqual(frame.maxY, cardTopY)
    }

    func testShortContentIsClampedToMinimumHeight() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 40
        )

        XCTAssertEqual(frame.height, MeterBarMenuDetailPanelLayout.minDetailHeight)
    }

    func testTallContentIsClampedToVisibleFrame() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 5000
        )

        let padding = MeterBarMenuDetailPanelLayout.screenPadding
        XCTAssertEqual(frame.height, visibleFrame.height - padding * 2)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + padding)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - padding)
    }

    func testLowCardShiftsPanelUpToStayOnScreen() {
        // Card near the bottom of the screen: aligning tops would push the
        // panel below the visible frame, so it shifts up instead.
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: visibleFrame.minY + 200
        )

        XCTAssertEqual(frame.minY, visibleFrame.minY + MeterBarMenuDetailPanelLayout.screenPadding)
    }

    func testPreferredTopAboveScreenIsClampedToPadding() {
        let frame = MeterBarMenuDetailPanelLayout.panelFrame(
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame,
            measuredHeight: 400,
            preferredTopY: visibleFrame.maxY + 100
        )

        XCTAssertEqual(frame.maxY, visibleFrame.maxY - MeterBarMenuDetailPanelLayout.screenPadding)
    }
}

/// Guards the hover detail panel against drifting from the popover card it opens
/// from. The two surfaces hand-rolled separate headers and the panel grew a
/// divider, a section heading and per-row card surfaces the card never had, so
/// hovering a card swapped in something that read like a different provider.
@MainActor
final class MenuBarProviderDetailParityTests: XCTestCase {
    private func snapshot(hoursSinceRefresh: Double = 0) -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: Date().addingTimeInterval(-hoursSinceRefresh * 3600),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    private func cursorSnapshot() -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "cursor",
            title: "Cursor",
            service: .cursor,
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

    /// The parity that matters: both surfaces derive their identity row from the
    /// same component, so neither can quietly start showing a different field.
    func testDetailPanelHeaderMatchesTheCardHeader() {
        let snapshot = snapshot()

        XCTAssertEqual(
            MenuBarProviderDetailContent(snapshot: snapshot).headerContent,
            ProviderStatusCard(snapshot: snapshot).headerContent
        )
    }

    /// The panel used to label itself with the service name, which the card
    /// already shows as its title. The refresh time is the field that adds
    /// something.
    func testHeaderShowsRefreshTimeRatherThanServiceName() {
        let snapshot = snapshot(hoursSinceRefresh: 2)
        let content = ProviderCardHeader.Content(snapshot: snapshot)

        XCTAssertEqual(content.title, snapshot.title)
        XCTAssertEqual(content.subtitle, snapshot.updatedText)
        XCTAssertNotEqual(content.subtitle, snapshot.service.displayName)
    }

    /// The panel dropped the status word entirely, so a stale or logged-out
    /// provider looked healthy the moment the pointer landed on it.
    func testHeaderCarriesTheSameStatusWordAsTheCard() {
        let healthy = snapshot()
        XCTAssertEqual(
            ProviderCardHeader.Content(snapshot: healthy).statusText,
            ProviderCardPresentation.statusText(for: healthy)
        )

        let loginRequired = ProviderSnapshotBuilder.snapshot(
            title: "shipshitdev",
            service: .claudeCode,
            metrics: nil,
            emptyDetail: "Run claude login"
        )
        XCTAssertEqual(
            ProviderCardHeader.Content(snapshot: loginRequired).statusText,
            ProviderCardPresentation.statusText(for: loginRequired)
        )
    }

    func testDetailPanelRendersAtPanelWidth() {
        let content = MenuBarProviderDetailContent(snapshot: snapshot())
        let host = NSHostingView(
            rootView: content.frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The panel's height is measured from its hosted content, so anything added
    /// to it grows the window. Seven bars is the reason the size was chosen over
    /// ``DailyUsageChart``'s thirty, and this pins that it stays a strip: 600pt
    /// is comfortably inside the visible frame of the smallest display MeterBar
    /// runs on (1280×800), so the panel never has to fall back to its scrolling
    /// variant just because the chart is present.
    func testTheSevenDayStripKeepsThePanelWithinASmallScreen() {
        let content = MenuBarProviderDetailContent(
            snapshot: snapshot(),
            dailyUsage: ProviderDailyUsageSeries(
                service: .codexCli,
                dailyUsage: (0..<7).map { offset in
                    DailyTokenUsage(
                        date: Date().addingTimeInterval(Double(-offset) * 86_400),
                        provider: .codexCli,
                        inputTokens: 900_000,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        estimatedCostUSD: 12
                    )
                }
            )
        )
        let host = NSHostingView(
            rootView: content.frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThan(host.fittingSize.height, 600)
    }

    /// The whole point of the change: hovering has to return something the card
    /// could not already show. If the strip ever stops rendering, the panel
    /// silently goes back to being a wider copy of the card.
    func testTheStripAddsHeightTheCardCopyDidNotHave() {
        let plain = NSHostingView(
            rootView: MenuBarProviderDetailContent(snapshot: snapshot())
                .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        let charted = NSHostingView(
            rootView: MenuBarProviderDetailContent(
                snapshot: snapshot(),
                dailyUsage: ProviderDailyUsageSeries(service: .codexCli, dailyUsage: [])
            )
            .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        plain.layoutSubtreeIfNeeded()
        charted.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(charted.fittingSize.height, plain.fittingSize.height)
    }

    func testCursorWithoutLedgerHistoryOmitsTheStripEntirely() {
        let plain = NSHostingView(
            rootView: MenuBarProviderDetailContent(snapshot: cursorSnapshot())
                .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        let withEmptySeries = NSHostingView(
            rootView: MenuBarProviderDetailContent(
                snapshot: cursorSnapshot(),
                dailyUsage: ProviderDailyUsageSeries.make(
                    service: .cursor,
                    dailyUsage: [],
                    ledger: ProviderUsageLedger(),
                    accountCount: 1
                )
            )
            .frame(width: MeterBarMenuDetailPanelLayout.detailWidth)
        )
        plain.layoutSubtreeIfNeeded()
        withEmptySeries.layoutSubtreeIfNeeded()

        XCTAssertEqual(plain.fittingSize.height, withEmptySeries.fittingSize.height)
    }

    func testHeaderAlwaysRendersInlineStatusWithOrWithoutDisclosureChevron() throws {
        for showsChevron in [true, false] {
            let currentSnapshot = snapshot()
            let expectedStatus = ProviderCardPresentation.statusText(for: currentSnapshot)
            let header = ProviderCardHeader(
                snapshot: currentSnapshot,
                showsDisclosureChevron: showsChevron
            )
            let host = NSHostingView(rootView: header.frame(width: 320))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()

            let logo = try XCTUnwrap(
                accessibilityElement(identifier: "provider-card-header-logo", in: host),
                "Provider logo should render when chevron is \(showsChevron)"
            )
            let title = try XCTUnwrap(
                accessibilityElement(identifier: "provider-card-header-title", in: host),
                "Provider title should render when chevron is \(showsChevron)"
            )
            let status = try XCTUnwrap(
                accessibilityElement(identifier: "provider-card-header-status", in: host),
                "Provider status should render when chevron is \(showsChevron)"
            )

            XCTAssertEqual(
                status.accessibilityLabel(),
                expectedStatus,
                "Provider status should render when chevron is \(showsChevron)"
            )
            XCTAssertEqual(
                logo.accessibilityFrame().midY,
                title.accessibilityFrame().midY,
                accuracy: 1,
                "Provider logo and title should stay on one row when chevron is \(showsChevron)"
            )
            XCTAssertEqual(
                title.accessibilityFrame().midY,
                status.accessibilityFrame().midY,
                accuracy: 1,
                "Provider title and status should stay on one row when chevron is \(showsChevron)"
            )
            XCTAssertGreaterThan(
                host.fittingSize.height,
                0,
                "ProviderCardHeader(chevron: \(showsChevron)) should keep status inline"
            )
        }
    }

    private func accessibilityElement(
        identifier: String,
        in element: Any
    ) -> NSAccessibilityElement? {
        if let accessibleElement = element as? NSAccessibilityElement,
           accessibleElement.accessibilityIdentifier() == identifier {
            return accessibleElement
        }

        for child in accessibilityChildren(of: element) {
            if let match = accessibilityElement(identifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func accessibilityChildren(of element: Any) -> [Any] {
        if let view = element as? NSView {
            return view.accessibilityChildren() ?? []
        }
        if let accessibleElement = element as? NSAccessibilityElement {
            return accessibleElement.accessibilityChildren() ?? []
        }
        return []
    }
}
