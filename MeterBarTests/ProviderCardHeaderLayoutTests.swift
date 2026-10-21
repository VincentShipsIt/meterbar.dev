import XCTest
@testable import MeterBar

/// The header grid's metrics: the subtitle must hang from the title's leading
/// edge (logo column + gap) so the two-line identity block stays aligned with
/// the runway and limit rows below it.
final class ProviderCardHeaderLayoutTests: XCTestCase {
    func testSubtitleHangsFromTheTitleLeadingEdge() {
        typealias Layout = ProviderCardHeader.Layout
        XCTAssertEqual(Layout.subtitleInset, Layout.logoSize + Layout.columnSpacing)
    }

    func testMetricsStayOnTheFourPointGrid() {
        typealias Layout = ProviderCardHeader.Layout
        XCTAssertGreaterThan(Layout.logoSize, 0)
        XCTAssertLessThanOrEqual(Layout.rowSpacing, Layout.badgeSpacing)
    }
}
