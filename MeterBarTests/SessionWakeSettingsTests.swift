import XCTest
@testable import MeterBar

/// Coverage for #98: settings toggle rules, account reconciliation, and the
/// notification gate.
final class SessionWakeSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SessionWakeSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> SessionWakeSettingsStore {
        SessionWakeSettingsStore(userDefaults: defaults)
    }

    func testDefaultsAreOffAndConservative() {
        let store = makeStore()
        XCTAssertFalse(store.featureEnabled)
        XCTAssertFalse(store.watcherArmed)
        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.canArmWatcher)
    }

    func testWatcherCannotArmWithoutFeatureAndAcknowledgement() {
        let store = makeStore()
        store.setWatcherArmed(true)
        XCTAssertFalse(store.watcherArmed, "Arming must be refused while the feature is off")

        store.setFeatureEnabled(true)
        store.setWatcherArmed(true)
        XCTAssertFalse(store.watcherArmed, "Arming must be refused without the first-enable ack")

        store.setFirstEnableAcknowledged(true)
        store.setWatcherArmed(true)
        XCTAssertTrue(store.watcherArmed)
    }

    func testFeatureOffForcesWatcherOff() {
        let store = makeStore()
        store.setFeatureEnabled(true)
        store.setFirstEnableAcknowledged(true)
        store.setWatcherArmed(true)
        XCTAssertTrue(store.watcherArmed)

        store.setFeatureEnabled(false)
        XCTAssertFalse(store.watcherArmed, "Master off must cancel watcher intent")
    }

    func testBypassModeWithoutAcknowledgementCannotArm() {
        let store = makeStore()
        store.setFeatureEnabled(true)
        store.setFirstEnableAcknowledged(true)
        store.setPermissionMode(.bypass)
        XCTAssertFalse(store.canArmWatcher)
        store.setWatcherArmed(true)
        XCTAssertFalse(store.watcherArmed)

        store.setBypassAcknowledged(true)
        XCTAssertTrue(store.canArmWatcher)
        store.setWatcherArmed(true)
        XCTAssertTrue(store.watcherArmed)

        // Revoking the ack while armed under bypass disarms.
        store.setBypassAcknowledged(false)
        XCTAssertFalse(store.watcherArmed)
    }

    func testWakeAccountPersistsAcrossRelaunch() {
        let id = UUID()
        let store = makeStore()
        store.setWakeAccountID(id)
        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.wakeAccountID, id)
    }

    func testRemovingSelectedAccountClearsItAndDisarms() {
        let id = UUID()
        let store = makeStore()
        store.setFeatureEnabled(true)
        store.setFirstEnableAcknowledged(true)
        store.setWakeAccountID(id)
        store.setWatcherArmed(true)
        XCTAssertTrue(store.watcherArmed)

        store.reconcileAccounts(available: [UUID(), UUID()]) // selected id gone
        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.watcherArmed)
    }

    func testBoundsClampThroughStore() {
        let store = makeStore()
        store.setMaxSessionsPerRun(9_999)
        store.setMaxTurns(0)
        XCTAssertEqual(store.maxSessionsPerRun, WakeBounds.sessionsRange.upperBound)
        XCTAssertEqual(store.maxTurns, WakeBounds.maxTurnsRange.lowerBound)
        XCTAssertEqual(store.bounds.maxSessionsPerRun, store.maxSessionsPerRun)
    }

    // MARK: - Notification gate

    func testNotificationRequiresGlobalProviderAndWakePreference() {
        func decide(_ global: Bool, _ provider: Bool, _ wake: Bool) -> Bool {
            SessionWakeNotificationDecider.shouldNotifyOnCompletion(
                .init(globalNotificationsEnabled: global, claudeProviderEnabled: provider, notifyOnCompletion: wake)
            )
        }
        XCTAssertTrue(decide(true, true, true))
        XCTAssertFalse(decide(false, true, true))
        XCTAssertFalse(decide(true, false, true))
        XCTAssertFalse(decide(true, true, false))
    }
}
