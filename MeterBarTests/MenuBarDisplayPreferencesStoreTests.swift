import MeterBarShared
import XCTest
@testable import MeterBar

final class MenuBarDisplayPreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarDisplayPreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsPreserveCurrentPresentation() {
        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)

        XCTAssertNil(store.pinnedCandidateKey)
        XCTAssertEqual(store.labelMetric, .percentLeft)
        XCTAssertEqual(store.labelSize, .compact)
        XCTAssertEqual(store.resetTimeFormat, .countdown)
    }

    func testPreferencesPersistAcrossRelaunch() {
        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)
        store.setPinnedCandidateKey("codex:account-id:weekly")
        store.setLabelMetric(.percentUsed)
        store.setLabelSize(.regular)
        store.setResetTimeFormat(.clock)

        let reloaded = MenuBarDisplayPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.pinnedCandidateKey, "codex:account-id:weekly")
        XCTAssertEqual(reloaded.labelMetric, .percentUsed)
        XCTAssertEqual(reloaded.labelSize, .regular)
        XCTAssertEqual(reloaded.resetTimeFormat, .clock)
    }

    func testInvalidPersistedValuesFallBackToExistingDefaults() {
        defaults.set("invalid", forKey: StorageKeys.statusItemLabelMetric)
        defaults.set("invalid", forKey: StorageKeys.statusItemLabelSize)
        defaults.set("invalid", forKey: StorageKeys.popoverResetTimeFormat)

        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.labelMetric, .percentLeft)
        XCTAssertEqual(store.labelSize, .compact)
        XCTAssertEqual(store.resetTimeFormat, .countdown)
    }

    func testBlankPinRestoresAutoAndRemovesPersistence() {
        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)
        store.setPinnedCandidateKey("codex:account-id:weekly")

        store.setPinnedCandidateKey("   ")

        XCTAssertNil(store.pinnedCandidateKey)
        XCTAssertNil(defaults.string(forKey: StorageKeys.statusItemPinnedCandidate))
    }

    func testLabelFormatterCoversMetricAndDensityOptions() {
        let limit = UsageLimit(used: 42.4, total: 100, resetTime: nil)

        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: limit, metric: .percentLeft, size: .compact),
            "58%"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: limit, metric: .percentLeft, size: .regular),
            "58% left"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: limit, metric: .percentUsed, size: .compact),
            "42%"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: limit, metric: .percentUsed, size: .regular),
            "42% used"
        )
        XCTAssertNil(StatusItemLabelFormatter.title(for: limit, metric: .iconOnly, size: .regular))
    }
}
