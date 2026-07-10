import XCTest
@testable import MeterBar

@MainActor
final class SessionWakeCoordinatorTests: XCTestCase {
    func testRestingStatusReflectsIntent() {
        XCTAssertEqual(
            SessionWakeCoordinator.restingStatus(featureEnabled: false, watcherArmed: false),
            .off
        )
        XCTAssertEqual(
            SessionWakeCoordinator.restingStatus(featureEnabled: true, watcherArmed: false),
            .idle
        )
        XCTAssertEqual(
            SessionWakeCoordinator.restingStatus(featureEnabled: true, watcherArmed: true),
            .armed
        )
        XCTAssertEqual(
            SessionWakeCoordinator.restingStatus(featureEnabled: false, watcherArmed: true),
            .off,
            "A disabled feature is always Off regardless of stale armed intent."
        )
    }

    func testReflectSettingsUpdatesRestingStatesOnly() {
        let coordinator = PreviewSessionWakeCoordinator(status: .idle)
        coordinator.reflectSettings(featureEnabled: true, watcherArmed: true)
        XCTAssertEqual(coordinator.status, .armed)

        coordinator.reflectSettings(featureEnabled: false, watcherArmed: false)
        XCTAssertEqual(coordinator.status, .off)
    }

    func testReflectSettingsDoesNotStompActiveRun() {
        let coordinator = PreviewSessionWakeCoordinator(status: .running(completed: 1, total: 3))
        coordinator.reflectSettings(featureEnabled: true, watcherArmed: false)
        XCTAssertEqual(
            coordinator.status,
            .running(completed: 1, total: 3),
            "Settings reflection must not overwrite an in-flight run."
        )
    }

    func testStubPreviewIsInertAndReportsUnavailable() async {
        let stub = StubSessionWakeCoordinator()
        await stub.preview()
        XCTAssertEqual(stub.eligibility?.eligibleCount, 0)
        XCTAssertNotNil(stub.eligibility?.note, "The stub honestly reports discovery is unavailable.")
    }

    func testSharedCoordinatorIsInstalled() {
        // The seam always has a coordinator; until #95–#97 land it is the stub.
        XCTAssertTrue(SessionWakeCoordinator.shared is StubSessionWakeCoordinator)
    }
}
