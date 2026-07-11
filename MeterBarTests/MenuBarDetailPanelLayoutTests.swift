import XCTest
@testable import MeterBar

final class MenuBarDetailPanelLayoutTests: XCTestCase {
    // A 1512x950 visible frame with the popover anchored near the top right,
    // mirroring the real menu-bar panel placement (AppKit bottom-left origin).
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let anchorFrame = CGRect(x: 1100, y: 300, width: 390, height: 600)

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
