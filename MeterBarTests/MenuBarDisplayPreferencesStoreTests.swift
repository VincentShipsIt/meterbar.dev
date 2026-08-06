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
        XCTAssertEqual(store.windowMode, .selected)
        XCTAssertEqual(store.fontSize, .standard)
        XCTAssertFalse(store.highContrast)
        XCTAssertFalse(store.showsExhaustedResetCountdown)
        XCTAssertEqual(store.resetTimeFormat, .countdown)
        // The popover keeps its pre-feature layout until the hint is asked for.
        XCTAssertFalse(store.showsRecommendationHint)
    }

    func testPreferencesPersistAcrossRelaunch() {
        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)
        store.setPinnedCandidateKey("codex:account-id:weekly")
        store.setLabelMetric(.percentUsed)
        store.setLabelSize(.regular)
        store.setWindowMode(.combined)
        store.setFontSize(.large)
        store.setHighContrast(true)
        store.setShowsExhaustedResetCountdown(true)
        store.setResetTimeFormat(.clock)
        store.setShowsRecommendationHint(true)

        let reloaded = MenuBarDisplayPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.pinnedCandidateKey, "codex:account-id:weekly")
        XCTAssertEqual(reloaded.labelMetric, .percentUsed)
        XCTAssertEqual(reloaded.labelSize, .regular)
        XCTAssertEqual(reloaded.windowMode, .combined)
        XCTAssertEqual(reloaded.fontSize, .large)
        XCTAssertTrue(reloaded.highContrast)
        XCTAssertTrue(reloaded.showsExhaustedResetCountdown)
        XCTAssertEqual(reloaded.resetTimeFormat, .clock)
        XCTAssertTrue(reloaded.showsRecommendationHint)
    }

    func testInvalidPersistedValuesFallBackToExistingDefaults() {
        defaults.set("invalid", forKey: StorageKeys.statusItemLabelMetric)
        defaults.set("invalid", forKey: StorageKeys.statusItemLabelSize)
        defaults.set("invalid", forKey: StorageKeys.statusItemWindowMode)
        defaults.set("invalid", forKey: StorageKeys.statusItemFontSize)
        defaults.set("invalid", forKey: StorageKeys.popoverResetTimeFormat)

        let store = MenuBarDisplayPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.labelMetric, .percentLeft)
        XCTAssertEqual(store.labelSize, .compact)
        XCTAssertEqual(store.windowMode, .selected)
        XCTAssertEqual(store.fontSize, .standard)
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

    func testPaceFormatterUsesBoundedVisibleAbbreviationsAndFullSpokenCopy() {
        let reserve = UsageLimit(
            used: 28,
            total: 100,
            resetTime: Date(timeIntervalSince1970: 8 * 60 * 60),
            windowSeconds: 10 * 60 * 60
        )
        let now = Date(timeIntervalSince1970: 5 * 60 * 60)

        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: reserve, metric: .pace, size: .compact, now: now),
            "R42%"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: reserve, metric: .pace, size: .regular, now: now),
            "42% reserve"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.spokenValue(for: reserve, metric: .pace, now: now),
            "42% in reserve"
        )
    }

    func testEstimatedOrUncomputablePaceIsUnknownRatherThanZero() {
        let missingWindow = UsageLimit(used: 50, total: 100, resetTime: nil)
        let estimated = UsageLimit(
            used: 50,
            total: 100,
            resetTime: Date().addingTimeInterval(3_600),
            windowSeconds: 7_200,
            isEstimated: true
        )

        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: missingWindow, metric: .pace, size: .compact),
            "—"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.title(for: estimated, metric: .pace, size: .regular),
            "—"
        )
        XCTAssertEqual(
            StatusItemLabelFormatter.spokenValue(for: missingWindow, metric: .pace),
            "pace unavailable"
        )
    }
}
