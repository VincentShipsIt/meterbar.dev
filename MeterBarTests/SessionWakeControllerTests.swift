import Combine
@testable import MeterBar
import XCTest

/// Coverage for the runtime wiring: the single toggle actually starts and stops
/// a live watcher, and the watcher keeps watching (continuous) rather than
/// stopping after one pass.
@MainActor
final class SessionWakeControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SessionWakeControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func poll(_ timeout: TimeInterval = 2, until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            pump(0.05)
        }
    }

    /// Store with the default account already selected + acknowledged, ready to
    /// turn on. The default account always exists in ClaudeCodeAccountStore.
    private func armedStore() -> SessionWakeSettingsStore {
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeAccountID(ClaudeCodeAccount.defaultID)
        store.acknowledgeFirstRunAndTurnOn()
        return store
    }

    func testWatcherReArmsOnLaunchWhenToggleWasLeftOn() {
        let store = armedStore()
        XCTAssertTrue(store.isOn)

        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )

        controller.activate() // initial reconcile re-arms
        XCTAssertTrue(controller.isWatching)
        poll { recorder.startCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.startCount, 1)
    }

    func testTogglingOffStopsTheWatcher() {
        let store = armedStore()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        XCTAssertTrue(controller.isWatching)
        poll { recorder.startCount >= 1 } // ensure the watch is genuinely in-flight
        XCTAssertGreaterThanOrEqual(recorder.startCount, 1)

        store.setOn(false)
        poll { !controller.isWatching } // let the Combine sink deliver
        XCTAssertFalse(controller.isWatching)
        poll { recorder.stopCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
    }

    func testSwitchingAccountWhileArmedStopsTheWatcher() {
        // Two real, resolvable accounts: the always-present default (A) plus a
        // custom one (B), so the controller can start a watch against either.
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Second", configDirectory: "/tmp/session-wake-second")
        guard let accountB = accounts.customAccounts.first?.id else {
            return XCTFail("adding a custom account should yield a resolvable id")
        }

        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeAccountID(ClaudeCodeAccount.defaultID) // account A
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: accounts,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        XCTAssertTrue(controller.isWatching)
        poll { recorder.startCount >= 1 } // watch against A is genuinely in-flight
        XCTAssertGreaterThanOrEqual(recorder.startCount, 1)

        // Switch the wake account while the watcher is ON. The live watcher must
        // not stay bound to the old account: the store disarms and the controller
        // tears the watch down.
        store.setWakeAccountID(accountB)
        poll { !controller.isWatching }
        XCTAssertFalse(controller.isWatching)
        XCTAssertFalse(store.isOn)
        poll { recorder.stopCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
    }

    func testDisablingSelectedAccountStopsWatcherAndClearsSelection() {
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        let store = armedStore()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: accounts,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        poll { recorder.startCount >= 1 }

        accounts.setEnabled(false, for: ClaudeCodeAccount.defaultID)

        poll { !controller.isWatching }
        XCTAssertFalse(controller.isWatching)
        XCTAssertFalse(store.isOn)
        XCTAssertNil(store.wakeAccountID)
        poll { recorder.stopCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
    }

    func testStaysOffWhenToggleOff() {
        let store = SessionWakeSettingsStore(userDefaults: defaults) // off
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(recorder.startCount, 0)
    }
}

// MARK: - Doubles

nonisolated private final class WatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func recordStart() { lock.lock(); starts += 1; lock.unlock() }
    func recordStop() { lock.lock(); stops += 1; lock.unlock() }
}

nonisolated private struct FakeWatcher: WakeWatching {
    let recorder: WatchRecorder
    let onState: @Sendable (WakeWatcherState) -> Void

    func start(account: ClaudeCodeAccount) async {
        recorder.recordStart()
        onState(.scanning)
    }

    func stop() async {
        recorder.recordStop()
        onState(.off)
    }

    func waitUntilFinished() async {
        // Model an ongoing watch: stay in-flight until the controller cancels
        // the surrounding task (i.e. the toggle went off).
        onState(.running(sessionID: "fake"))
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
