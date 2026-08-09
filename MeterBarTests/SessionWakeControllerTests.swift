import Combine
import Darwin
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
        try? FileManager.default.removeItem(at: testLockURL())
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
        let lockURL = testLockURL()
        return { WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .app) }
    }

    private func testLockURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/session-wake-tests", isDirectory: true)
            .appendingPathComponent("\(suiteName ?? UUID().uuidString)-watcher.lock")
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )
        controller.activate()
        XCTAssertTrue(controller.isWatching)
        poll { recorder.startCount >= 1 }
        XCTAssertEqual(recorder.startedProviders.first, .codex)
    }

    func testReconcileWhileArmedOnSameIdentityDoesNotRecreateWatcher() {
        let store = armedStore()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in
                recorder.recordCreation()
                return FakeWatcher(recorder: recorder, onState: onState)
            },
            makeLifetimeLock: lifetimeLockFactory()
        )
        controller.activate()
        poll { recorder.startCount >= 1 }
        XCTAssertEqual(recorder.creationCount, 1)

        store.prompt = "Continue after the same quota window reopens."
        pump(0.2)

        XCTAssertEqual(recorder.creationCount, 1)
        XCTAssertEqual(recorder.startCount, 1)
        store.setOn(false)
    }

    func testReArmingAfterProviderSwitchRestartsWatcherOnNewProvider() {
        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeAccountID(ClaudeCodeAccount.defaultID)
        store.setWakeCodexAccountID(CodexAccount.defaultID)
        store.acknowledgeFirstRunAndTurnOn()
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
        poll { recorder.startCount >= 1 }

        store.setWakeProvider(.codex)
        store.setOn(true)
        poll { recorder.startCount >= 2 }

        XCTAssertTrue(store.isOn)
        XCTAssertEqual(recorder.startedProviders, [.claude, .codex])
        store.setOn(false)
    }

    func testReArmingAfterAccountSwitchRestartsWatcherOnNewAccount() {
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        let accountDirectory = "/tmp/session-wake-rearmed-account"
        accounts.addAccount(name: "Second", configDirectory: accountDirectory)
        guard let accountID = accounts.customAccounts.first?.id else {
            return XCTFail("adding a custom account should yield a resolvable id")
        }
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

        store.setWakeAccountID(accountID)
        store.setOn(true)
        poll { recorder.startCount >= 2 }

        XCTAssertTrue(store.isOn)
        XCTAssertEqual(recorder.lastStartedAccountLabel, accountDirectory)
        store.setOn(false)
    }

    func testTargetSwitchWaitsForOldLifetimeLockReleaseBeforeReArming() {
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Second", configDirectory: "/tmp/session-wake-lock-sequencing")
        guard let accountID = accounts.customAccounts.first?.id else {
            return XCTFail("adding a custom account should yield a resolvable id")
        }
        let store = armedStore()
        let sessionStatus = SessionWakeStatus()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: accounts,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )
        controller.activate()
        poll { recorder.startCount >= 1 }

        store.setWakeAccountID(accountID)
        store.setOn(true)
        poll { recorder.startCount >= 2 }

        XCTAssertEqual(recorder.startCount, 2)
        if case let .failed(reason) = sessionStatus.watcherState {
            XCTAssertFalse(reason.contains("Another Session Wake holder is active"), reason)
        }
        store.setOn(false)
    }

    func testImmediateStopThenStartWaitsForCleanupAndReleasesEachLifetimeLockOnce() {
        let store = armedStore()
        let sessionStatus = SessionWakeStatus()
        let recorder = WatchRecorder()
        let completionGate = WatchCompletionGate()
        let lifetimeLocks = LifetimeLockRecorder(lockURL: testLockURL())
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in
                recorder.recordCreation()
                if recorder.creationCount == 1 {
                    return DelayedFinishWatcher(
                        recorder: recorder,
                        completionGate: completionGate,
                        onState: onState
                    )
                }
                return FakeWatcher(recorder: recorder, onState: onState)
            },
            makeLifetimeLock: lifetimeLocks.factory()
        )
        controller.activate()
        defer {
            completionGate.finish()
            store.setOn(false)
            pump(0.2)
        }
        poll { completionGate.waitCount == 1 }
        XCTAssertEqual(recorder.startCount, 1)

        store.setOn(false)
        poll { !controller.isWatching && recorder.stopCount >= 1 }
        store.setOn(true)
        pump(0.2)

        XCTAssertEqual(recorder.creationCount, 1, "re-arm must wait while the outgoing watcher still owns the lock")
        if case let .failed(reason) = sessionStatus.watcherState {
            XCTFail("the app must not report its outgoing watcher as external contention: \(reason)")
        }

        completionGate.finish()
        poll { recorder.startCount >= 2 }

        XCTAssertTrue(controller.isWatching)
        XCTAssertEqual(recorder.startCount, 2)
        XCTAssertEqual(recorder.creationCount, 2)
        XCTAssertEqual(lifetimeLocks.creationCount, 2)
        XCTAssertEqual(lifetimeLocks.releaseCount, 1, "only the outgoing lifetime lock should be released")
        if case let .failed(reason) = sessionStatus.watcherState {
            XCTFail("re-arm should succeed after cleanup completes: \(reason)")
        }

        store.setOn(false)
        poll { lifetimeLocks.releaseCount >= 2 }
        XCTAssertEqual(lifetimeLocks.releaseCount, 2, "each lifetime lock should be released exactly once")
    }

    func testDifferentPIDLifetimeLockHolderStillReportsContention() throws {
        let lockURL = testLockURL()
        let holder = try SpawnedWakeLockHolder(lockURL: lockURL)
        defer { holder.release() }
        poll {
            guard let data = try? Data(contentsOf: lockURL),
                  let record = try? JSONDecoder().decode(WakeLockHolder.self, from: data) else { return false }
            return record.pid == holder.pid
        }
        XCTAssertNotEqual(holder.pid, getpid())

        let store = armedStore()
        let sessionStatus = SessionWakeStatus()
        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: sessionStatus,
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )

        controller.activate()
        pump(0.2)

        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(recorder.startCount, 0)
        guard case let .failed(reason) = sessionStatus.watcherState else {
            return XCTFail("a different process holding the lifetime lock must report contention")
        }
        XCTAssertTrue(reason.contains("Another Session Wake holder is active"), reason)
        XCTAssertTrue(reason.contains("pid \(holder.pid)"), reason)
    }

    func testDisablingSelectedCodexAccountStopsWatcherAndClearsSelection() {
        let codexAccounts = CodexAccountStore(userDefaults: defaults)
        codexAccounts.addAccount(name: "Work", homeDirectory: "/tmp/session-wake-codex")
        guard let selectedID = codexAccounts.customAccounts.first?.id else {
            return XCTFail("adding a Codex account should yield a resolvable id")
        }

        let store = SessionWakeSettingsStore(userDefaults: defaults)
        store.setWakeProvider(.codex)
        store.setWakeCodexAccountID(selectedID)
        store.acknowledgeFirstRunAndTurnOn()

        let recorder = WatchRecorder()
        let controller = SessionWakeController(
            store: store,
            status: SessionWakeStatus(),
            accounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: codexAccounts,
            rescanInterval: 3_600,
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
        )
        controller.activate()
        poll { recorder.startCount >= 1 }

        XCTAssertEqual(codexAccounts.setEnabled(false, for: selectedID), .updated)

        poll { !controller.isWatching }
        XCTAssertFalse(controller.isWatching)
        XCTAssertFalse(store.isOn)
        XCTAssertNil(store.wakeCodexAccountID)
        poll { recorder.stopCount >= 1 }
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
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
            makeWatcher: { _, _, onState in FakeWatcher(recorder: recorder, onState: onState) },
            makeLifetimeLock: lifetimeLockFactory()
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
    private var creations = 0
    private var starts = 0
    private var stops = 0
    private var providers: [WakeProvider] = []
    private var accountLabels: [String?] = []
    var creationCount: Int { lock.lock(); defer { lock.unlock() }; return creations }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var startedProviders: [WakeProvider] { lock.lock(); defer { lock.unlock() }; return providers }
    var startedAccountLabels: [String?] { lock.lock(); defer { lock.unlock() }; return accountLabels }
    var lastStartedAccountLabel: String? {
        lock.lock()
        defer { lock.unlock() }
        return accountLabels.last.flatMap { $0 }
    }
    func recordCreation() { lock.lock(); creations += 1; lock.unlock() }
    func recordStart(provider: WakeProvider, accountLabel: String?) {
        lock.lock(); starts += 1; providers.append(provider); accountLabels.append(accountLabel); lock.unlock()
    }
    func recordStop() { lock.lock(); stops += 1; lock.unlock() }
}

nonisolated private struct FakeWatcher: WakeWatching {
    let recorder: WatchRecorder
    let onState: @Sendable (WakeWatcherState) -> Void

    func start(runtime: WakeProviderRuntime) async {
        recorder.recordStart(provider: runtime.provider, accountLabel: runtime.accountLabel)
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

nonisolated private struct DelayedFinishWatcher: WakeWatching {
    let recorder: WatchRecorder
    let completionGate: WatchCompletionGate
    let onState: @Sendable (WakeWatcherState) -> Void

    func start(runtime: WakeProviderRuntime) async {
        recorder.recordStart(provider: runtime.provider, accountLabel: runtime.accountLabel)
        onState(.running(sessionID: "delayed"))
    }

    func stop() async {
        recorder.recordStop()
        onState(.off)
    }

    func waitUntilFinished() async {
        await completionGate.wait()
    }
}

nonisolated private final class WatchCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false
    private var waits = 0

    var waitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waits
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            waits += 1
            if isFinished {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

nonisolated private final class LifetimeLockRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let lockURL: URL
    private var creations = 0
    private var releases = 0

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return creations
    }

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    func factory() -> WakeLifetimeLockFactory {
        { [self] in
            lock.lock()
            creations += 1
            lock.unlock()
            return RecordingLifetimeLock(
                lock: WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .app),
                onRelease: { [self] in recordRelease() }
            )
        }
    }

    private func recordRelease() {
        lock.lock()
        releases += 1
        lock.unlock()
    }
}

nonisolated private final class RecordingLifetimeLock: WakeLifetimeLocking, @unchecked Sendable {
    private let lock: WakeLock
    private let onRelease: @Sendable () -> Void

    init(lock: WakeLock, onRelease: @escaping @Sendable () -> Void) {
        self.lock = lock
        self.onRelease = onRelease
    }

    func acquire() -> WakeLock.Acquisition {
        lock.acquire()
    }

    func release() {
        onRelease()
        lock.release()
    }
}

nonisolated private final class SpawnedWakeLockHolder {
    let pid: Int32
    private let process: Process
    private let input: Pipe
    private var isReleased = false

    init(lockURL: URL) throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, json, os, socket, sys, time
            with open(sys.argv[1], "w") as lock_file:
                fcntl.flock(lock_file, fcntl.LOCK_EX)
                json.dump({"kind": "agent", "pid": os.getpid(), "host": socket.gethostname(), \
                    "startedAtEpoch": time.time()}, lock_file)
                lock_file.flush()
                sys.stdin.buffer.read(1)
            """,
            lockURL.path,
        ]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        self.process = process
        self.input = input
        pid = process.processIdentifier
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        try? input.fileHandleForWriting.write(contentsOf: Data([1]))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit {
        release()
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
