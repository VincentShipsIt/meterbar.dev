import Combine
import Foundation

/// The lifecycle abstraction the controller drives. `WakeCoordinator` is the
/// production conformer; tests substitute a fake to assert start/stop without
/// spawning a subprocess.
protocol WakeWatching: Sendable {
    func start(account: ClaudeCodeAccount) async
    func stop() async
    func waitUntilFinished() async
}

extension WakeCoordinator: WakeWatching {}

/// Builds a watcher from a runner, bounds, and a state-change sink.
typealias WakeWatcherFactory = @Sendable (
    WakeExecuting,
    WakeBounds,
    @escaping @Sendable (WakeWatcherState) -> Void
) -> WakeWatching

/// Bridges the single ON/OFF toggle to a live, continuous watcher.
///
/// While `isOn`, it runs a `WakeCoordinator` pass (scan → wait for quota →
/// resume), and when a pass settles it re-scans after `rescanInterval` so the
/// watcher keeps watching for the *next* time a session hits its limit — rather
/// than stopping after one resume. Turning the toggle off, or removing the wake
/// account, tears the watcher down deterministically. v1 lifetime is
/// app-running-only: the watcher lives with the process and re-arms on launch
/// if the toggle was left on.
@MainActor
final class SessionWakeController: ObservableObject {
    static let shared = SessionWakeController()

    private let store: SessionWakeSettingsStore
    private let status: SessionWakeStatus
    private let accounts: ClaudeCodeAccountStore
    private let rescanInterval: TimeInterval
    private let makeWatcher: WakeWatcherFactory

    private var cancellables = Set<AnyCancellable>()
    private var watchTask: Task<Void, Never>?
    private var started = false

    init(
        store: SessionWakeSettingsStore = .shared,
        status: SessionWakeStatus = .shared,
        accounts: ClaudeCodeAccountStore = .shared,
        rescanInterval: TimeInterval = 300,
        makeWatcher: @escaping WakeWatcherFactory = { runner, bounds, onState in
            WakeCoordinator(runner: runner, bounds: bounds, onState: onState)
        }
    ) {
        self.store = store
        self.status = status
        self.accounts = accounts
        self.rescanInterval = rescanInterval
        self.makeWatcher = makeWatcher
    }

    /// Begin observing the toggle and re-arm if it was left on. Idempotent;
    /// call once from the app delegate at launch.
    func activate() {
        guard !started else { return }
        started = true

        // Any change that affects whether/where we should watch triggers a
        // reconcile: the toggle, the selected account, the permission posture,
        // and the account list (a removed account disarms via the store).
        Publishers.Merge4(
            store.$isOn.map { _ in () },
            store.$wakeAccountID.map { _ in () },
            store.$permissionMode.map { _ in () },
            store.$bypassAcknowledged.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.reconcile() }
        .store(in: &cancellables)

        accounts.$customAccounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.reconcileAccounts(available: self.accounts.accounts.map(\.id))
                self.reconcile()
            }
            .store(in: &cancellables)

        reconcile()
    }

    /// Whether the controller currently has a live watch task (test hook).
    var isWatching: Bool { watchTask != nil }

    // MARK: - Reconciliation

    private func reconcile() {
        if store.isOn, let account = selectedAccount() {
            startWatching(account: account)
        } else {
            stopWatching()
        }
    }

    private func selectedAccount() -> ClaudeCodeAccount? {
        guard let id = store.wakeAccountID else { return nil }
        return accounts.accounts.first { $0.id == id }
    }

    private func startWatching(account: ClaudeCodeAccount) {
        guard watchTask == nil else { return }
        let bounds = store.bounds
        let runner = WakeProcessRunner(
            account: account,
            permissionMode: store.permissionMode,
            bypassAcknowledged: store.bypassAcknowledged,
            prompt: store.prompt
        )
        let interval = rescanInterval
        let make = makeWatcher

        watchTask = Task {
            while !Task.isCancelled {
                let watcher = make(runner, bounds) { state in
                    Task { @MainActor in SessionWakeStatus.shared.update(state: state) }
                }
                await watcher.start(account: account)
                // A cancel (toggle off) reliably stops the coordinator via the
                // cancellation handler, regardless of where the pass is.
                await withTaskCancellationHandler {
                    await watcher.waitUntilFinished()
                } onCancel: {
                    Task { await watcher.stop() }
                }
                if Task.isCancelled { break }
                // Keep watching for the next limit hit.
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    private func stopWatching() {
        guard watchTask != nil else { return }
        watchTask?.cancel()
        watchTask = nil
        status.update(state: .off)
    }
}
