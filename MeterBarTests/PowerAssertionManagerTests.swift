import MeterBarShared
import XCTest
@testable import MeterBar

final class PowerAssertionManagerTests: XCTestCase {
    private final class FakeAssertionController: PowerAssertionControlling {
        var acquireSucceeds = true
        var releaseSucceeds = true
        private(set) var acquiredProviders: [ServiceType] = []
        private(set) var releaseCallCount = 0
        private(set) var isHeld = false

        func acquire(for provider: ServiceType) -> Bool {
            acquiredProviders.append(provider)
            isHeld = acquireSucceeds
            return acquireSucceeds
        }

        @discardableResult
        func release() -> Bool {
            releaseCallCount += 1
            if releaseSucceeds {
                isHeld = false
            }
            return releaseSucceeds
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "PowerAssertionManagerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEnabledEligibleProviderAcquiresExactlyOnce() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)

        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 20)])
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 21)])

        XCTAssertEqual(controller.acquiredProviders, [.claudeCode])
        XCTAssertEqual(controller.releaseCallCount, 0)
        XCTAssertTrue(controller.isHeld)
        XCTAssertTrue(manager.isAssertionHeld)
        XCTAssertEqual(manager.activeProvider, .claudeCode)
    }

    func testDepletionReleasesHeldAssertionWithoutLeaking() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)
        manager.reconcile(snapshots: [snapshot(.codexCli, used: 40)])

        manager.reconcile(snapshots: [snapshot(.codexCli, used: 100)])

        XCTAssertEqual(controller.releaseCallCount, 1)
        XCTAssertFalse(controller.isHeld)
        XCTAssertFalse(manager.isAssertionHeld)
        XCTAssertNil(manager.activeProvider)
    }

    func testProviderDisableReleasesHeldAssertionWithoutLeaking() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 40)])

        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 40, isProviderEnabled: false)])

        XCTAssertEqual(controller.releaseCallCount, 1)
        XCTAssertFalse(controller.isHeld)
        XCTAssertFalse(manager.isAssertionHeld)
    }

    func testShutdownReleasesHeldAssertionWithoutChangingPersistedIntent() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 40)])

        manager.shutdown()

        XCTAssertEqual(controller.releaseCallCount, 1)
        XCTAssertFalse(controller.isHeld)
        XCTAssertFalse(manager.isAssertionHeld)
        XCTAssertTrue(StayAwakeSettingsStore(userDefaults: defaults).isEnabled)
    }

    func testSwitchingProviderReleasesBeforeAcquiringReplacement() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 40)])

        manager.reconcile(snapshots: [
            snapshot(.claudeCode, used: 40, isProviderEnabled: false),
            snapshot(.codexCli, used: 20),
        ])

        XCTAssertEqual(controller.releaseCallCount, 1)
        XCTAssertEqual(controller.acquiredProviders, [.claudeCode, .codexCli])
        XCTAssertTrue(controller.isHeld)
        XCTAssertEqual(manager.activeProvider, .codexCli)
    }

    func testFailedAcquireNeverReportsHeldAssertion() {
        let controller = FakeAssertionController()
        controller.acquireSucceeds = false
        let manager = makeManager(controller: controller, enabled: true)

        manager.reconcile(snapshots: [snapshot(.cursor, used: 20)])

        XCTAssertFalse(controller.isHeld)
        XCTAssertFalse(manager.isAssertionHeld)
        XCTAssertNil(manager.activeProvider)
    }

    func testFailedReleaseKeepsAssertionVisibleForRetry() {
        let controller = FakeAssertionController()
        let manager = makeManager(controller: controller, enabled: true)
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 20)])
        controller.releaseSucceeds = false

        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 100)])

        XCTAssertTrue(controller.isHeld)
        XCTAssertTrue(manager.isAssertionHeld)
        XCTAssertEqual(manager.activeProvider, .claudeCode)

        controller.releaseSucceeds = true
        manager.reconcile(snapshots: [snapshot(.claudeCode, used: 100)])
        XCTAssertFalse(manager.isAssertionHeld)
    }

    func testAssertionNameIdentifiesMeterBarAndProvider() {
        XCTAssertEqual(
            IOKitPowerAssertionController.assertionName(for: .codexCli),
            "MeterBar Stay Awake — OpenAI Codex"
        )
    }

    private func makeManager(
        controller: FakeAssertionController,
        enabled: Bool
    ) -> PowerAssertionManager {
        let store = StayAwakeSettingsStore(userDefaults: defaults)
        store.setEnabled(enabled)
        return PowerAssertionManager(store: store, assertionController: controller)
    }

    private func snapshot(
        _ provider: ServiceType,
        used: Double,
        isProviderEnabled: Bool = true
    ) -> StayAwakeUsageSnapshot {
        StayAwakeUsageSnapshot(
            provider: provider,
            isProviderEnabled: isProviderEnabled,
            sessionUsedPercentage: used
        )
    }
}
