import XCTest
@testable import MeterBar

final class StayAwakeSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "StayAwakeSettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsOff() {
        XCTAssertFalse(StayAwakeSettingsStore(userDefaults: defaults).isEnabled)
    }

    func testEnabledStateSurvivesRelaunch() {
        let store = StayAwakeSettingsStore(userDefaults: defaults)
        store.setEnabled(true)

        XCTAssertTrue(StayAwakeSettingsStore(userDefaults: defaults).isEnabled)
    }

    func testDisablingPersists() {
        let store = StayAwakeSettingsStore(userDefaults: defaults)
        store.setEnabled(true)
        store.setEnabled(false)

        XCTAssertFalse(StayAwakeSettingsStore(userDefaults: defaults).isEnabled)
    }
}
