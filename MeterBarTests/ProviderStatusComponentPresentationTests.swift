import Foundation
@testable import MeterBar
import XCTest

final class ProviderStatusComponentPresentationTests: XCTestCase {
    private func component(
        _ id: String,
        status: String = "operational",
        children: [ProviderStatusComponent] = []
    ) -> ProviderStatusComponent {
        ProviderStatusComponent(
            id: id,
            name: id,
            indicator: .componentIndicator(for: status),
            status: status,
            children: children
        )
    }

    func testShortHealthyListIsNotTruncated() {
        let components = (1...5).map { component("c\($0)") }

        let presentation = ProviderStatusComponentPresentation.make(components: components)

        XCTAssertEqual(presentation.visible.map(\.id), ["c1", "c2", "c3", "c4", "c5"])
        XCTAssertEqual(presentation.hiddenCount, 0)
        XCTAssertFalse(presentation.isTruncated)
    }

    func testLongHealthyListCapsAtFiveAndCountsTheRest() {
        let components = (1...23).map { component("c\($0)") }

        let presentation = ProviderStatusComponentPresentation.make(components: components)

        XCTAssertEqual(presentation.visible.map(\.id), ["c1", "c2", "c3", "c4", "c5"])
        XCTAssertEqual(presentation.hiddenCount, 18)
        XCTAssertTrue(presentation.isTruncated)
    }

    func testExpandedShowsEveryComponent() {
        let components = (1...23).map { component("c\($0)") }

        let presentation = ProviderStatusComponentPresentation.make(components: components, expanded: true)

        XCTAssertEqual(presentation.visible.count, 23)
        XCTAssertEqual(presentation.hiddenCount, 0)
        XCTAssertFalse(presentation.isTruncated)
    }

    func testDegradedComponentsAreNeverHiddenBehindHealthyOnes() {
        var components = (1...10).map { component("c\($0)") }
        components[7] = component("c8", status: "partial_outage")
        components[9] = component("c10", status: "degraded_performance")

        let presentation = ProviderStatusComponentPresentation.make(components: components)

        XCTAssertEqual(presentation.visible.map(\.id), ["c8", "c10", "c1", "c2", "c3"])
        XCTAssertEqual(presentation.hiddenCount, 5)
    }

    func testGroupWithDegradedChildCountsAsIssue() {
        let group = component(
            "group",
            children: [component("child-ok"), component("child-down", status: "major_outage")]
        )
        let components = (1...6).map { component("c\($0)") } + [group]

        let presentation = ProviderStatusComponentPresentation.make(components: components)

        XCTAssertEqual(presentation.visible.first?.id, "group")
        XCTAssertEqual(presentation.visible.count, 5)
        XCTAssertEqual(presentation.hiddenCount, 2)
    }

    func testCustomLimitIsHonoured() {
        let components = (1...4).map { component("c\($0)") }

        let presentation = ProviderStatusComponentPresentation.make(components: components, limit: 2)

        XCTAssertEqual(presentation.visible.map(\.id), ["c1", "c2"])
        XCTAssertEqual(presentation.hiddenCount, 2)
    }
}
