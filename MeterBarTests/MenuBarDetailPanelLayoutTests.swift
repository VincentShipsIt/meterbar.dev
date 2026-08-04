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

    func testHeaderRendersWithAndWithoutTheDisclosureChevron() {
        for showsChevron in [true, false] {
            let header = ProviderCardHeader(snapshot: snapshot(), showsDisclosureChevron: showsChevron)
            let host = NSHostingView(rootView: header.frame(width: 320))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(
                host.fittingSize.height,
                0,
                "ProviderCardHeader(showsDisclosureChevron: \(showsChevron)) should lay out"
            )
        }
    }
}
