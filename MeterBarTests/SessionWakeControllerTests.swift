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
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName ?? "")-watcher.lock")
        )
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

    private func lifetimeLockFactory() -> @Sendable () -> WakeLock {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName ?? UUID().uuidString)-watcher.lock")
        return { WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .app) }
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )
        controller.activate()
        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(recorder.startCount, 0)
    }

    func testDefaultProviderStartsClaudeRuntime() {
        // The default provider is Claude; the watcher is armed with a Claude
        // runtime (the existing behavior, now asserted explicitly).
        let store = armedStore()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        poll { recorder.startCount >= 1 }
        XCTAssertEqual(recorder.startedProviders.first, .claude)
    }

    func testCodexProviderStartsCodexRuntime() {
        // Selecting the Codex provider + a Codex account arms the watcher with a
        // Codex runtime — the app-watcher Codex path this change adds.
        let codexAccounts = CodexAccountStore(userDefaults: defaults)
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeProvider(.codex)
        store.setWakeCodexAccountID(CodexAccount.defaultID)
        store.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(store.isOn)

        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: codexAccounts,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        XCTAssertTrue(controller.isWatching)
        poll { recorder.startCount >= 1 }
        XCTAssertEqual(recorder.startedProviders.first, .codex)
    }

    func testSwitchingProviderWhileArmedStopsTheWatcher() {
        let store = armedStore() // Claude, armed
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) }
        )
        controller.activate()
        poll { recorder.startCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.startCount, 1)

        // Switching the provider disarms (store.forceOff) ⇒ watcher tears down.
        store.setWakeProvider(.codex)
        poll { !controller.isWatching }
        XCTAssertFalse(controller.isWatching)
        XCTAssertFalse(store.isOn)
        poll { recorder.stopCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
    }

    func testReleaseBundleHandsWatchingToManagedAgentAndDisarmUnregisters() {
        let store = armedStore()
        let recorder = WatchRecorder()
        let fakeAgent = FakeSessionWakeAgent()
        let agentSuite = "SessionWakeControllerAgent-\(UUID().uuidString)"
        let agentDefaults = UserDefaults(suiteName: agentSuite)
        guard let agentDefaults else { return XCTFail("agent defaults should be available") }
        defer { agentDefaults.removePersistentDomain(forName: agentSuite) }
        let agentState = SessionWakeAgentStateStore(userDefaults: agentDefaults)
        agentState.saveStatus(.init(state: .idle))
        let sessionStatus = SessionWakeStatus()
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            agent: fakeAgent,
            agentStateStore: agentState,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )

        controller.activate()

        XCTAssertEqual(fakeAgent.registerCount, 1)
        XCTAssertEqual(recorder.startCount, 0, "managed bundles must not start a second in-app watcher")
        XCTAssertEqual(sessionStatus.backgroundExecution, .active)
        XCTAssertEqual(agentState.loadConfiguration()?.canRun, true)

        store.setOn(false)
        pump()

        XCTAssertEqual(fakeAgent.unregisterCount, 1)
        XCTAssertFalse(agentState.loadConfiguration()?.isArmed ?? true)
        XCTAssertEqual(sessionStatus.backgroundExecution, .inactive)
    }

    func testRegistrationFailureRemainsVisibleUntilSuccessfulRetry() {
        let store = armedStore()
        let fakeAgent = FakeSessionWakeAgent()
        fakeAgent.registerError = FakeSessionWakeAgentError.registrationDenied
        let agentState = SessionWakeAgentStateStore(userDefaults: defaults)
        agentState.saveStatus(.init(state: .idle))
        let sessionStatus = SessionWakeStatus()
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            agent: fakeAgent,
            agentStateStore: agentState
        )

        controller.activate()
        // Deliver the automatic off-state reconcile and the monitor's first
        // registration-status refresh; neither may erase the failure.
        pump(0.2)

        XCTAssertEqual(fakeAgent.registerCount, 1)
        XCTAssertFalse(store.isOn)
        XCTAssertEqual(
            sessionStatus.backgroundExecution,
            .failed("Couldn't start the background watcher: operation not permitted")
        )
        guard case let .failed(reason) = sessionStatus.watcherState else {
            return XCTFail("registration failure should remain visible in the watcher status")
        }
        XCTAssertTrue(reason.contains("operation not permitted"))

        fakeAgent.registerError = nil
        store.setOn(true)
        pump(0.2)

        XCTAssertEqual(fakeAgent.registerCount, 2)
        XCTAssertTrue(store.isOn)
        XCTAssertEqual(sessionStatus.backgroundExecution, .active)
        XCTAssertEqual(sessionStatus.watcherState, .idle)
    }

    func testRegistrationFailureThatRequiresApprovalShowsLoginItemsState() {
        let store = armedStore()
        let fakeAgent = FakeSessionWakeAgent()
        fakeAgent.registerError = FakeSessionWakeAgentError.registrationDenied
        fakeAgent.registerFailureStatus = .requiresApproval
        let sessionStatus = SessionWakeStatus()
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            agent: fakeAgent
        )

        controller.activate()
        pump(0.2)

        XCTAssertEqual(fakeAgent.registerCount, 1)
        XCTAssertFalse(store.isOn)
        XCTAssertEqual(sessionStatus.backgroundExecution, .requiresApproval)
        XCTAssertEqual(sessionStatus.watcherState, .off)
    }
}

// MARK: - Doubles

nonisolated private final class WatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var providers: [WakeProvider] = []
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var startedProviders: [WakeProvider] { lock.lock(); defer { lock.unlock() }; return providers }
    func recordStart(provider: WakeProvider) {
        lock.lock(); starts += 1; providers.append(provider); lock.unlock()
    }
    func recordStop() { lock.lock(); stops += 1; lock.unlock() }
}

nonisolated private struct FakeWatcher: WakeWatching {
    let recorder: WatchRecorder
    let onState: @Sendable (WakeWatcherState) -> Void

    func start(runtime: WakeProviderRuntime) async {
        recorder.recordStart(provider: runtime.provider)
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

private enum FakeSessionWakeAgentError: LocalizedError {
    case registrationDenied

    var errorDescription: String? { "operation not permitted" }
}

private final class FakeSessionWakeAgent: SessionWakeAgentControlling {
    var isAvailable = true
    private(set) var status: SessionWakeAgentRegistrationStatus = .notRegistered
    var registerError: Error?
    var registerFailureStatus: SessionWakeAgentRegistrationStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func currentStatus() -> SessionWakeAgentRegistrationStatus { status }

    func register() throws {
        registerCount += 1
        if let registerError {
            if let registerFailureStatus {
                status = registerFailureStatus
            }
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}
