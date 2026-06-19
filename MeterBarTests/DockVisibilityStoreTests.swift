import Combine
import XCTest
@testable import MeterBar

final class DockVisibilityStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DockVisibilityStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToShowingInDock() {
        let store = DockVisibilityStore(userDefaults: defaults)
        XCTAssertTrue(store.showInDock, "A fresh install should show MeterBar in the Dock by default.")
    }

    func testHidingFromDockPersists() {
        let store = DockVisibilityStore(userDefaults: defaults)

        store.setShowInDock(false)
        XCTAssertFalse(store.showInDock)

        let reloaded = DockVisibilityStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.showInDock, "Hiding from the Dock should survive a relaunch.")
    }

    func testShowingInDockPersistsAfterHiding() {
        defaults.set(false, forKey: "ShowMeterBarInDock")
        let store = DockVisibilityStore(userDefaults: defaults)
        XCTAssertFalse(store.showInDock)

        store.setShowInDock(true)
        XCTAssertTrue(store.showInDock)

        let reloaded = DockVisibilityStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.showInDock, "Re-showing in the Dock should survive a relaunch.")
    }

    func testSettingSameValueDoesNotPublishRedundantly() {
        let store = DockVisibilityStore(userDefaults: defaults)
        var publishedCount = 0
        let cancellable = store.$showInDock.dropFirst().sink { _ in publishedCount += 1 }

        store.setShowInDock(true) // already the default — no change expected
        XCTAssertEqual(publishedCount, 0)

        store.setShowInDock(false) // genuine change
        XCTAssertEqual(publishedCount, 1)

        cancellable.cancel()
    }
}
