import XCTest
@testable import MeterBar

/// Coverage for the single ON/OFF Session Wake toggle: first-run gate, account
/// requirement, permission gating, account reconciliation, and the notification
/// gate.
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

    func testDefaultsAreOff() {
        let store = makeStore()
        XCTAssertTrue(store.featureEnabled)
        XCTAssertFalse(store.isOn)
        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.canTurnOn)
        XCTAssertTrue(store.needsFirstRunConfirmation)
    }

    func testMasterFeatureFlagOffForcesWatcherOffAndPreventsArming() {
        let store = makeStore()
        store.setWakeAccountID(UUID())
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        store.setFeatureEnabled(false)

        XCTAssertFalse(store.featureEnabled)
        XCTAssertFalse(store.isOn)
        XCTAssertFalse(store.canTurnOn)
        store.setOn(true)
        XCTAssertFalse(store.isOn)
    }

    func testExplicitlyDisabledFeatureStaysDisabledAcrossRelaunch() {
        defaults.set(false, forKey: StorageKeys.sessionWakeFeatureEnabled)

        let store = makeStore()

        XCTAssertFalse(store.featureEnabled)
        XCTAssertFalse(store.isOn)
    }

    func testCannotTurnOnWithoutAccount() {
        let store = makeStore()
        store.acknowledgeFirstRunAndTurnOn() // no account yet
        XCTAssertFalse(store.isOn)
    }

    func testCannotTurnOnBeforeFirstRunAcknowledged() {
        let store = makeStore()
        store.setWakeAccountID(UUID())
        store.setOn(true) // not acknowledged yet
        XCTAssertFalse(store.isOn)
    }

    func testAcknowledgeAndTurnOnWithAccount() {
        let store = makeStore()
        store.setWakeAccountID(UUID())
        XCTAssertTrue(store.canTurnOn)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)
        XCTAssertFalse(store.needsFirstRunConfirmation)
        // Subsequent toggles no longer need confirmation.
        store.setOn(false)
        store.setOn(true)
        XCTAssertTrue(store.isOn)
    }

    func testBypassModeWithoutAcknowledgementCannotTurnOn() {
        let store = makeStore()
        store.setWakeAccountID(UUID())
        store.setPermissionMode(.bypass)
        XCTAssertFalse(store.canTurnOn)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertFalse(store.isOn)

        store.setBypassAcknowledged(true)
        XCTAssertTrue(store.canTurnOn)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        // Revoking the bypass acknowledgement turns it off.
        store.setBypassAcknowledged(false)
        XCTAssertFalse(store.isOn)
    }

    func testPersistsOnAcrossRelaunch() {
        let id = UUID()
        let store = makeStore()
        store.setWakeAccountID(id)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.isOn)
        XCTAssertEqual(reloaded.wakeAccountID, id)
        XCTAssertFalse(reloaded.needsFirstRunConfirmation)
    }

    func testRemovingSelectedAccountClearsItAndTurnsOff() {
        let id = UUID()
        let store = makeStore()
        store.setWakeAccountID(id)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        store.reconcileAccounts(available: [UUID(), UUID()]) // selected id gone
        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.isOn)
    }

    func testDisablingSelectedAccountClearsItAndTurnsOff() {
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        let store = makeStore()
        store.setWakeAccountID(ClaudeCodeAccount.defaultID)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        accounts.setEnabled(false, for: ClaudeCodeAccount.defaultID)
        store.reconcileAccounts(available: accounts.enabledAccounts.map(\.id))

        XCTAssertNil(store.wakeAccountID)
        XCTAssertFalse(store.isOn)
    }

    func testSwitchingAccountWhileArmedDisarms() {
        let accountA = UUID()
        let accountB = UUID()
        let store = makeStore()
        store.setWakeAccountID(accountA)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        // Switching the wake target while armed must disarm: automation may never
        // keep running against the old account, nor silently retarget the new one.
        store.setWakeAccountID(accountB)
        XCTAssertEqual(store.wakeAccountID, accountB)
        XCTAssertFalse(store.isOn)

        // The persisted flag is off too, so a relaunch stays off until re-armed.
        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.isOn)
        XCTAssertEqual(reloaded.wakeAccountID, accountB)
    }

    func testReselectingSameAccountWhileArmedStaysOn() {
        let account = UUID()
        let store = makeStore()
        store.setWakeAccountID(account)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        // A no-op re-selection of the already-selected account must not disarm.
        store.setWakeAccountID(account)
        XCTAssertTrue(store.isOn)
    }

    func testStaleOnWithoutAccountIsCorrectedAtLoad() {
        // Simulate a persisted "on" with no account (should not stay on).
        defaults.set(true, forKey: StorageKeys.sessionWakeWatcherArmed)
        defaults.set(true, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.isOn)
    }

    func testBoundsClampThroughStore() {
        let store = makeStore()
        store.setMaxSessionsPerRun(9_999)
        store.setMaxTurns(0)
        XCTAssertEqual(store.maxSessionsPerRun, WakeBounds.sessionsRange.upperBound)
        XCTAssertEqual(store.maxTurns, WakeBounds.maxTurnsRange.lowerBound)
        XCTAssertEqual(store.bounds.maxSessionsPerRun, store.maxSessionsPerRun)
    }

    func testNotificationRequiresGlobalProviderAndWakePreference() {
        func decide(_ global: Bool, _ provider: Bool, _ wake: Bool) -> Bool {
            SessionWakeNotificationDecider.shouldNotifyOnCompletion(
                .init(
                    globalNotificationsEnabled: global,
                    providerEnabled: provider,
                    providerDisplayName: "Claude Code",
                    notifyOnCompletion: wake
                )
            )
        }
        XCTAssertTrue(decide(true, true, true))
        XCTAssertFalse(decide(false, true, true))
        XCTAssertFalse(decide(true, false, true))
        XCTAssertFalse(decide(true, true, false))
    }

    // MARK: - Provider dimension

    func testDefaultProviderIsClaude() {
        let store = makeStore()
        XCTAssertEqual(store.wakeProvider, .claude)
        XCTAssertNil(store.wakeCodexAccountID)
        XCTAssertNil(store.activeAccountID)
    }

    func testActiveAccountIDFollowsProvider() {
        let claudeID = UUID()
        let codexID = UUID()
        let store = makeStore()
        store.setWakeAccountID(claudeID)
        store.setWakeCodexAccountID(codexID)

        XCTAssertEqual(store.activeAccountID, claudeID)
        store.setWakeProvider(.codex)
        XCTAssertEqual(store.activeAccountID, codexID)
    }

    func testCanTurnOnConsidersSelectedProviderAccount() {
        let store = makeStore()
        // Claude account selected, but the active provider is Codex ⇒ cannot arm.
        store.setWakeAccountID(UUID())
        store.setWakeProvider(.codex)
        XCTAssertFalse(store.canTurnOn)

        // Selecting a Codex account enables it.
        store.setWakeCodexAccountID(UUID())
        XCTAssertTrue(store.canTurnOn)
    }

    func testSwitchingProviderWhileArmedDisarms() {
        let store = makeStore()
        store.setWakeAccountID(UUID())
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        store.setWakeProvider(.codex)
        XCTAssertEqual(store.wakeProvider, .codex)
        XCTAssertFalse(store.isOn)

        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.wakeProvider, .codex)
        XCTAssertFalse(reloaded.isOn)
    }

    func testSwitchingCodexAccountWhileArmedDisarms() {
        let accountA = UUID()
        let accountB = UUID()
        let store = makeStore()
        store.setWakeProvider(.codex)
        store.setWakeCodexAccountID(accountA)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        store.setWakeCodexAccountID(accountB)
        XCTAssertEqual(store.wakeCodexAccountID, accountB)
        XCTAssertFalse(store.isOn)
    }

    func testReconcileCodexAccountsClearsMissingSelection() {
        let store = makeStore()
        store.setWakeProvider(.codex)
        store.setWakeCodexAccountID(UUID())
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        store.reconcileCodexAccounts(available: [UUID(), UUID()]) // selected id gone
        XCTAssertNil(store.wakeCodexAccountID)
        XCTAssertFalse(store.isOn)
    }

    func testProviderAndCodexAccountPersistAcrossRelaunch() {
        let codexID = UUID()
        let store = makeStore()
        store.setWakeProvider(.codex)
        store.setWakeCodexAccountID(codexID)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        let reloaded = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.wakeProvider, .codex)
        XCTAssertEqual(reloaded.wakeCodexAccountID, codexID)
        XCTAssertTrue(reloaded.isOn)
    }

    func testStaleOnWithoutCodexAccountIsCorrectedAtLoad() {
        // Persisted "on" for Codex with no Codex account selected must not arm.
        defaults.set(WakeProvider.codex.rawValue, forKey: StorageKeys.sessionWakeProvider)
        defaults.set(true, forKey: StorageKeys.sessionWakeWatcherArmed)
        defaults.set(true, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.isOn)
    }
}
