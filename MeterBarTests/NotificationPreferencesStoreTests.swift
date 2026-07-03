import Combine
import XCTest
@testable import MeterBar

final class NotificationPreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationPreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsPreserveLegacyBehavior() {
        let store = NotificationPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(store.isEnabled, "Notifications should be on by default, matching prior behavior.")
        XCTAssertEqual(store.warningThreshold, .critical)
        XCTAssertEqual(store.criticalThreshold, .exhausted)
    }

    func testDisablingPersists() {
        let store = NotificationPreferencesStore(userDefaults: defaults)
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)

        let reloaded = NotificationPreferencesStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.isEnabled, "The global toggle should survive a relaunch.")
    }

    func testThresholdSelectionsPersist() {
        let store = NotificationPreferencesStore(userDefaults: defaults)
        store.setWarningThreshold(.tight)
        store.setCriticalThreshold(.critical)

        let reloaded = NotificationPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.warningThreshold, .tight)
        XCTAssertEqual(reloaded.criticalThreshold, .critical)
    }

    func testPreferencesValueReflectsState() {
        let store = NotificationPreferencesStore(userDefaults: defaults)
        store.setEnabled(false)
        store.setWarningThreshold(.tight)

        let prefs = store.preferences
        XCTAssertFalse(prefs.isEnabled)
        XCTAssertEqual(prefs.warningThreshold, .tight)
        XCTAssertEqual(prefs.criticalThreshold, .exhausted)
    }

    func testSettingSameValueDoesNotPublishRedundantly() {
        let store = NotificationPreferencesStore(userDefaults: defaults)
        var publishedCount = 0
        let cancellable = store.$isEnabled.dropFirst().sink { _ in publishedCount += 1 }

        store.setEnabled(true) // already the default — no change expected
        XCTAssertEqual(publishedCount, 0)

        store.setEnabled(false) // genuine change
        XCTAssertEqual(publishedCount, 1)

        cancellable.cancel()
    }
}
