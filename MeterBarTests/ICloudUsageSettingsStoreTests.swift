import XCTest
@testable import MeterBar

final class ICloudUsageSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ICloudUsageSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fresh install

    @MainActor
    func testFreshInstallGeneratesAndPersistsADeviceID() {
        let store = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })

        let raw = defaults.string(forKey: StorageKeys.iCloudUsageDeviceID)
        XCTAssertEqual(raw, store.deviceID.uuidString)
        XCTAssertFalse(store.identityCollisionDetected)
    }

    // MARK: - Same Mac across launches

    @MainActor
    func testSameHardwareAcrossLaunchesKeepsTheSameDeviceIDAndNeverFlagsACollision() {
        let first = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })
        let firstID = first.deviceID

        let second = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })

        XCTAssertEqual(second.deviceID, firstID)
        XCTAssertFalse(second.identityCollisionDetected)
    }

    // MARK: - Two installs sharing a device ID (issue #548, part 2)

    /// Simulates a Migration Assistant / Time Machine clone: the destination
    /// Mac boots with a `UserDefaults` domain (device ID + hardware anchor)
    /// copied whole from the source Mac, but its own hardware answers a
    /// different anchor. Reusing the cloned ID would make two physical Macs
    /// write into the same CloudKit zone and silently overwrite each other's
    /// daily rollups instead of summing — the store must detect this and mint
    /// a fresh ID rather than propagate the collision.
    @MainActor
    func testClonedDefaultsOnDifferentHardwareRegeneratesTheDeviceIDAndFlagsTheCollision() {
        let source = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-source" })
        let sourceID = source.deviceID

        // The destination Mac's `UserDefaults` domain now looks exactly like
        // the source's (as Migration Assistant would leave it), but this Mac's
        // own hardware anchor is different.
        let destination = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-destination" })

        XCTAssertNotEqual(destination.deviceID, sourceID)
        XCTAssertTrue(destination.identityCollisionDetected)
        // The regenerated ID must actually be persisted, or the next launch
        // would detect the same collision again instead of settling.
        XCTAssertEqual(defaults.string(forKey: StorageKeys.iCloudUsageDeviceID), destination.deviceID.uuidString)
    }

    @MainActor
    func testCollisionRecoveryIsStableAcrossASubsequentLaunchOnTheSameDestinationHardware() {
        _ = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-source" })
        let destinationFirstLaunch = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-destination" })

        let destinationSecondLaunch = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-destination" })

        XCTAssertEqual(destinationSecondLaunch.deviceID, destinationFirstLaunch.deviceID)
        XCTAssertFalse(destinationSecondLaunch.identityCollisionDetected)
    }

    // MARK: - Upgrade path (no anchor recorded yet)

    /// An install that already has a saved device ID from before this fix
    /// shipped has no saved hardware anchor to compare against. That must not
    /// be treated as a collision — every existing single-Mac install would
    /// otherwise regenerate its ID (and lose its CloudKit history) on the
    /// first launch of the new build.
    @MainActor
    func testUpgradingAnInstallWithNoSavedAnchorKeepsTheExistingDeviceID() {
        let existingID = UUID()
        defaults.set(existingID.uuidString, forKey: StorageKeys.iCloudUsageDeviceID)

        let store = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })

        XCTAssertEqual(store.deviceID, existingID)
        XCTAssertFalse(store.identityCollisionDetected)
    }

    // MARK: - Hardware anchor unavailable

    /// When IOKit can't answer (anchor closure returns `nil`), the store must
    /// fail open rather than false-flag a collision, and must not clobber a
    /// previously-recorded anchor it could still use to detect a real
    /// collision on a later, successful launch.
    @MainActor
    func testUnavailableHardwareAnchorNeitherFlagsACollisionNorClearsTheSavedAnchor() {
        let first = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })
        let firstID = first.deviceID

        let second = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { nil })

        XCTAssertEqual(second.deviceID, firstID)
        XCTAssertFalse(second.identityCollisionDetected)

        // A genuinely different Mac, launched later while the anchor lookup is
        // unavailable, still can't be distinguished from a clone — documented
        // as this approach's tradeoff — but the *previously recorded* anchor
        // must survive so a subsequent successful read can still catch it.
        let third = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-b" })
        XCTAssertNotEqual(third.deviceID, firstID)
        XCTAssertTrue(third.identityCollisionDetected)
    }

    // MARK: - Existing behavior (regression coverage)

    @MainActor
    func testSetEnabledTogglingOffAlsoTurnsOffShowsAllMacs() {
        let store = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })
        store.setEnabled(true)
        store.setShowsAllMacs(true)
        XCTAssertTrue(store.showsAllMacs)

        store.setEnabled(false)

        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.showsAllMacs)
    }

    @MainActor
    func testSetDeviceNameTrimsWhitespaceAndPersists() {
        let store = ICloudUsageSettingsStore(userDefaults: defaults, hardwareAnchor: { "hw-a" })

        store.setDeviceName("  Studio  ")

        XCTAssertEqual(store.deviceName, "Studio")
        XCTAssertEqual(defaults.string(forKey: StorageKeys.iCloudUsageDeviceName), "Studio")
    }

    // MARK: - Hardware anchor helper

    func testCurrentHardwareAnchorReadsAStableNonEmptyValueOnThisMachine() {
        let anchor = ICloudUsageSettingsStore.currentHardwareAnchor()

        // Best-effort on CI: IOKit's platform UUID is expected to be readable
        // on real hardware/VMs the way `swift test` runs here, but this must
        // not crash or hang if it's ever unavailable in a sandboxed runner.
        if let anchor {
            XCTAssertFalse(anchor.isEmpty)
        }
    }
}
