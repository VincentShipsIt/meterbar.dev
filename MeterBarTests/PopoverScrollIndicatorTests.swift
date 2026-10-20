import XCTest

@testable import MeterBar

final class PopoverScrollIndicatorTests: XCTestCase {
    func testShortContentHasNoThumb() {
        let metrics = PopoverScrollMetrics(offset: 0, content: 300, viewport: 400)
        XCTAssertFalse(metrics.isScrollable)
        XCTAssertEqual(metrics.thumb(minimumLength: 28).length, 0)
    }

    func testThumbLengthIsTheVisibleShareOfTheContent() {
        let metrics = PopoverScrollMetrics(offset: 0, content: 800, viewport: 400)
        let thumb = metrics.thumb(minimumLength: 28)
        XCTAssertEqual(thumb.length, 200, accuracy: 0.01)
        XCTAssertEqual(thumb.top, 0, accuracy: 0.01)
    }

    func testThumbReachesTheBottomAtTheEndOfTheContent() {
        let metrics = PopoverScrollMetrics(offset: 400, content: 800, viewport: 400)
        let thumb = metrics.thumb(minimumLength: 28)
        XCTAssertEqual(thumb.top + thumb.length, 400, accuracy: 0.01)
    }

    func testThumbNeverShrinksBelowTheMinimumOrLeavesTheTrack() {
        let metrics = PopoverScrollMetrics(offset: 99_999, content: 20_000, viewport: 400)
        let thumb = metrics.thumb(minimumLength: 28)
        XCTAssertEqual(thumb.length, 28, accuracy: 0.01)
        XCTAssertLessThanOrEqual(thumb.top + thumb.length, 400.01)
    }
}
