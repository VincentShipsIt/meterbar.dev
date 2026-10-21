import MeterBarShared
import XCTest
@testable import MeterBar

final class PopoverRoutingLineTests: XCTestCase {
    private let catalog = RoutingPolicyCatalog()

    func testShowsTaskAndRecommendedRoute() throws {
        let line = try XCTUnwrap(PopoverRoutingLine.make(
            task: .implementation,
            catalog: catalog,
            candidates: [RoutingFixtures.candidate(.claudeCode, used: 20)],
            now: RoutingFixtures.now
        ))

        XCTAssertEqual(line.taskName, "Implementation")
        XCTAssertTrue(line.route.contains("Claude"), line.route)
        XCTAssertTrue(line.text.hasPrefix("Implementation"), line.text)
        XCTAssertTrue(line.text.contains(line.route), line.text)
    }

    func testNoRouteShowsNoLine() {
        XCTAssertNil(PopoverRoutingLine.make(
            task: .implementation,
            catalog: catalog,
            candidates: [],
            now: RoutingFixtures.now
        ))
    }

    func testUnknownTaskShowsNoLine() throws {
        let custom = try XCTUnwrap(RoutingTaskID(token: "my-own-task"))

        XCTAssertNil(PopoverRoutingLine.make(
            task: custom,
            catalog: catalog,
            candidates: [RoutingFixtures.candidate(.claudeCode, used: 20)],
            now: RoutingFixtures.now
        ))
    }

    func testFollowsTheChosenTask() throws {
        let candidates = [RoutingFixtures.candidate(.claudeCode, used: 20)]
        let planning = try XCTUnwrap(PopoverRoutingLine.make(
            task: .planning, catalog: catalog, candidates: candidates, now: RoutingFixtures.now
        ))

        XCTAssertEqual(planning.taskName, "Planning")
    }

    func testPickerOptionsAreEveryTaskInTheCatalog() {
        XCTAssertEqual(PopoverRoutingLine.options(in: catalog).map(\.id), RoutingTaskID.builtIn)
    }

    @MainActor
    func testReadsRunOffMainThreadAndCancelledResultsAreDiscarded() async {
        let started = expectation(description: "background read started")
        let unblock = DispatchSemaphore(value: 0)
        let expected = PopoverRoutingLine(taskName: "Implementation", route: "Codex")
        let request = Task {
            await PopoverRoutingLine.load(for: .implementation) { task in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(task, .implementation)
                started.fulfill()
                _ = unblock.wait(timeout: .now() + 5)
                return expected
            }
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        unblock.signal()
        let result = await request.value
        XCTAssertNil(result)
    }

    func testCurrentRequestReturnsItsRecommendation() async {
        let expected = PopoverRoutingLine(taskName: "Planning", route: "Codex")
        let result = await PopoverRoutingLine.load(for: .planning) { _ in expected }
        XCTAssertEqual(result, expected)
    }
}
