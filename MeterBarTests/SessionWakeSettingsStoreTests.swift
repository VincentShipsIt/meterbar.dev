import Combine
import XCTest
@testable import MeterBar

final class SessionWakeSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionWakeSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> SessionWakeSettingsStore {
        SessionWakeSettingsStore(userDefaults: defaults)
    }

    // MARK: Defaults

    func testDefaultsAreSafeAndOff() {
        let store = makeStore()
        XCTAssertFalse(store.isFeatureEnabled)
        XCTAssertFalse(store.isWatcherArmed)
        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.hasAcknowledgedFirstEnable)
        XCTAssertFalse(store.hasAcknowledgedPermissionBypass)
        XCTAssertTrue(store.notifyOnCompletion, "Completion notifications default on.")
        XCTAssertTrue(store.notifyOnWatchStart)
    }

    // MARK: First-enable acknowledgement gates enabling

    func testEnablingRequiresFirstEnableAcknowledgement() {
        let store = makeStore()

        store.setFeatureEnabled(true)
        XCTAssertFalse(store.isFeatureEnabled, "Feature must not enable without acknowledgement.")

        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        XCTAssertTrue(store.isFeatureEnabled, "After acknowledgement, enabling succeeds.")
    }

    // MARK: Feature vs watcher separation

    func testWatcherCannotArmWhileFeatureOff() {
        let store = makeStore()
        store.acknowledgeFirstEnable()
        store.selectWakeAccount(UUID())

        // Feature still off.
        store.setWatcherArmed(true)
        XCTAssertFalse(store.isWatcherArmed, "Watcher cannot arm while the feature is off.")
    }

    func testWatcherCannotArmWithoutSelectedAccount() {
        let store = makeStore()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)

        store.setWatcherArmed(true)
        XCTAssertFalse(store.isWatcherArmed, "Watcher cannot arm without an explicit account.")
        XCTAssertFalse(store.canArmWatcher)
    }

    func testWatcherArmsWhenAllPreconditionsHold() {
        let store = makeStore()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        store.selectWakeAccount(UUID())

        XCTAssertTrue(store.canArmWatcher)
        store.setWatcherArmed(true)
        XCTAssertTrue(store.isWatcherArmed)
    }

    func testDisablingFeatureForcesWatcherOff() {
        let store = makeStore()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        store.selectWakeAccount(UUID())
        store.setWatcherArmed(true)
        XCTAssertTrue(store.isWatcherArmed)

        store.setFeatureEnabled(false)
        XCTAssertFalse(store.isFeatureEnabled)
        XCTAssertFalse(store.isWatcherArmed, "Master-off cancels watcher intent.")
    }

    // MARK: Account selection safety

    func testChangingAccountWhileArmedDisarms() {
        let store = makeStore()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        store.selectWakeAccount(UUID())
        store.setWatcherArmed(true)
        XCTAssertTrue(store.isWatcherArmed)

        store.selectWakeAccount(UUID())
        XCTAssertFalse(store.isWatcherArmed, "Switching accounts safely suspends the watcher.")
    }

    func testReconcileClearsRemovedAccountAndSuspends() {
        let store = makeStore()
        let account = UUID()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        store.selectWakeAccount(account)
        store.setWatcherArmed(true)

        // The account list no longer contains the selection.
        store.reconcile(availableAccountIDs: [UUID()])
        XCTAssertNil(store.wakeAccountID, "A removed account clears the selection.")
        XCTAssertFalse(store.isWatcherArmed, "A removed account suspends the watcher.")
    }

    func testReconcileKeepsStillPresentAccount() {
        let store = makeStore()
        let account = UUID()
        store.acknowledgeFirstEnable()
        store.setFeatureEnabled(true)
        store.selectWakeAccount(account)
        store.setWatcherArmed(true)

        store.reconcile(availableAccountIDs: [account, UUID()])
        XCTAssertEqual(store.wakeAccountID, account)
        XCTAssertTrue(store.isWatcherArmed)
    }

    // MARK: Persistence

    func testSelectionAndIntentSurviveRelaunch() {
        let account = UUID()
        do {
            let store = makeStore()
            store.acknowledgeFirstEnable()
            store.setFeatureEnabled(true)
            store.selectWakeAccount(account)
            store.setWatcherArmed(true)
            store.setNotifyOnCompletion(false)
        }

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.isFeatureEnabled)
        XCTAssertTrue(reloaded.isWatcherArmed)
        XCTAssertEqual(reloaded.wakeAccountID, account)
        XCTAssertFalse(reloaded.notifyOnCompletion)
    }

    func testWatcherNeverResurrectsWhenFeatureDisabledOnLoad() {
        // Simulate a corrupt/hand-edited defaults blob: armed=true but feature=false.
        defaults.set(true, forKey: StorageKeys.sessionWakeWatcherArmed)
        defaults.set(false, forKey: StorageKeys.sessionWakeFeatureEnabled)
        defaults.set(true, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)

        let store = makeStore()
        XCTAssertFalse(store.isWatcherArmed, "A disabled feature must never load an armed watcher.")
    }

    func testPermissionBypassIsSeparateAndPersists() {
        do {
            let store = makeStore()
            XCTAssertFalse(store.hasAcknowledgedPermissionBypass)
            store.setPermissionBypassAcknowledged(true)
        }
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.hasAcknowledgedPermissionBypass)
    }

    // MARK: Publish hygiene

    func testNoRedundantPublishOnUnchangedNotify() {
        let store = makeStore()
        var count = 0
        let cancellable = store.$notifyOnCompletion.dropFirst().sink { _ in count += 1 }

        store.setNotifyOnCompletion(true) // already the default
        XCTAssertEqual(count, 0)

        store.setNotifyOnCompletion(false)
        XCTAssertEqual(count, 1)

        cancellable.cancel()
    }
}
