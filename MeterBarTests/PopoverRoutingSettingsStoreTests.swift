import MeterBarShared
import XCTest
@testable import MeterBar

final class PopoverRoutingSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "PopoverRoutingSettingsStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToImplementation() {
        XCTAssertEqual(PopoverRoutingSettingsStore(userDefaults: defaults).task, .implementation)
    }

    func testChosenTaskSurvivesRelaunch() {
        PopoverRoutingSettingsStore(userDefaults: defaults).setTask(.planning)

        XCTAssertEqual(PopoverRoutingSettingsStore(userDefaults: defaults).task, .planning)
    }

    func testUnreadableStoredValueFallsBackToDefault() {
        defaults.set("not a task!!", forKey: StorageKeys.popoverRoutingTask)

        XCTAssertEqual(PopoverRoutingSettingsStore(userDefaults: defaults).task, .implementation)
    }

    func testStoresTheTaskTokenOnly() {
        PopoverRoutingSettingsStore(userDefaults: defaults).setTask(.quickEdit)

        XCTAssertEqual(defaults.string(forKey: StorageKeys.popoverRoutingTask), "quick-edit")
    }
}
