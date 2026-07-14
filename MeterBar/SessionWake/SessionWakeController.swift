import Combine
import Foundation
import MeterBarShared

/// The lifecycle abstraction the controller drives. `WakeCoordinator` is the
/// production conformer; tests substitute a fake to assert start/stop without
/// spawning a subprocess.
///
/// The watcher is armed with a provider `runtime` (Claude or Codex), so the
/// controller stays provider-agnostic. `WakeCoordinator` still offers a concrete
/// `start(account:)` convenience for the legacy Claude path, but it is not part
/// of this protocol.
nonisolated protocol WakeWatching: Sendable {
    func start(runtime: WakeProviderRuntime) async
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
/// Signed release bundles register the embedded `meterbar wake-agent` launch
/// agent so the watcher survives app quit and relaunch. Development/SwiftPM
/// builds do not contain that helper and retain the in-process watcher as a
/// deterministic fallback. Both modes hold the same lifetime lock, so app,
/// agent, and one-shot CLI work are mutually exclusive.
@MainActor
final class SessionWakeController: ObservableObject {
    static let shared = SessionWakeController()

    private let store: SessionWakeSettingsStore
    private let status: SessionWakeStatus
    private let accounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore
    private let notificationPreferences: NotificationPreferencesStore
    private let providerVisibility: ProviderVisibilityStore
    private let agent: SessionWakeAgentControlling
    private let agentStateStore: SessionWakeAgentStateStore
    private let rescanInterval: TimeInterval
    private let makeWatcher: WakeWatcherFactory
    private let makeLifetimeLock: @Sendable () -> WakeLock

    private var cancellables = Set<AnyCancellable>()
    private var watchTask: Task<Void, Never>?
    private var localLifetimeLock: WakeLock?
    private var agentMonitorTask: Task<Void, Never>?
    private var started = false

    /// The store defaults are `nil` sentinels resolved in the body because the
    /// MainActor-isolated singletons cannot appear in (nonisolated) default
    /// argument position.
    init(
        store: SessionWakeSettingsStore? = nil,
        status: SessionWakeStatus? = nil,
        accounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        notificationPreferences: NotificationPreferencesStore? = nil,
        providerVisibility: ProviderVisibilityStore? = nil,
        agent: SessionWakeAgentControlling? = nil,
        agentStateStore: SessionWakeAgentStateStore? = nil,
        rescanInterval: TimeInterval = 300,
        makeWatcher: @escaping WakeWatcherFactory = { runner, bounds, onState in
            WakeCoordinator(runner: runner, bounds: bounds, onState: onState)
        },
        makeLifetimeLock: @escaping @Sendable () -> WakeLock = { WakeLock(holderKind: .app) }
    ) {
        self.store = store ?? .shared
        self.status = status ?? .shared
        self.accounts = accounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.notificationPreferences = notificationPreferences ?? .shared
        self.providerVisibility = providerVisibility ?? .shared
        self.agent = agent ?? SMAppServiceSessionWakeAgent()
        self.agentStateStore = agentStateStore ?? SessionWakeAgentStateStore()
        self.rescanInterval = rescanInterval
        self.makeWatcher = makeWatcher
        self.makeLifetimeLock = makeLifetimeLock
    }

    /// Begin observing the toggle and re-arm if it was left on. Idempotent;
    /// call once from the app delegate at launch.
    func activate() {
        guard !started else { return }
        started = true

        // Any change that affects whether/where/how we should watch triggers a
        // reconcile: the feature flag, the toggle, the active provider, either
        // provider's selected account, the permission posture, and the run
        // parameters. A removed account disarms via the store's reconcilers below.
        let triggers: [AnyPublisher<Void, Never>] = [
            store.$featureEnabled.map { _ in () }.eraseToAnyPublisher(),
            store.$isOn.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeProvider.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeAccountID.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeCodexAccountID.map { _ in () }.eraseToAnyPublisher(),
            store.$permissionMode.map { _ in () }.eraseToAnyPublisher(),
            store.$bypassAcknowledged.map { _ in () }.eraseToAnyPublisher(),
            store.$prompt.map { _ in () }.eraseToAnyPublisher(),
            store.$notifyOnCompletion.map { _ in () }.eraseToAnyPublisher(),
            store.$maxSessionsPerRun.map { _ in () }.eraseToAnyPublisher(),
            store.$maxTurns.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &cancellables)

        Publishers.Merge(
            notificationPreferences.$isEnabled.map { _ in () },
            providerVisibility.$hiddenServices.map { _ in () }
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)

        Publishers.Merge(
            accounts.$customAccounts.map { _ in () },
            accounts.$defaultAccountIsEnabled.map { _ in () }
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.reconcileAccounts(available: self.accounts.enabledAccounts.map(\.id))
                self.reconcile()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            codexAccounts.$customAccounts.map { _ in () },
            codexAccounts.$defaultAccountIsEnabled.map { _ in () }
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.reconcileCodexAccounts(available: self.codexAccounts.enabledAccounts.map(\.id))
                self.reconcile()
            }
            .store(in: &cancellables)

        reconcile()
        startAgentMonitorIfNeeded()
    }

    /// Whether the controller currently has a live watch task (test hook).
    var isWatching: Bool { watchTask != nil }

    /// Whether this installed bundle can hand the watcher to launchd. Debug
    /// builds without the injected CLI remain in-process.
    var usesBackgroundAgent: Bool { agent.isAvailable }

    // MARK: - Reconciliation

    private func reconcile() {
        let account = selectedAccount()
        saveAgentConfiguration(account: account)

        if store.isOn, usesBackgroundAgent, account != nil {
            // Installed bundle: hand the watch to the launchd agent (Claude only).
            stopWatching()
            registerAgentIfNeeded()
        } else if store.isOn, let runtime = resolvedRuntime() {
            // Dev build / no agent: watch in-process, provider-aware (Claude or Codex).
            unregisterAgentIfNeeded()
            startWatching(runtime: runtime)
        } else {
            stopWatching()
            unregisterAgentIfNeeded()
        }
        // Keep the app-group target the bundled CLI reads in step with the
        // active provider's selection, independent of the app watcher toggle —
        // `meterbar wake` may run from cron even when the watcher is off.
        store.syncSharedWakeTarget(directory: activeAccountDirectory())
    }

    /// The selected, enabled Claude account (nil for Codex or when none is
    /// selected). Used by the launchd agent path, which is Claude-only.
    private func selectedAccount() -> ClaudeCodeAccount? {
        guard store.wakeProvider == .claude, let id = store.wakeAccountID else { return nil }
        return accounts.enabledAccounts.first { $0.id == id }
    }

    /// Build the runtime for the active provider bound to its selected, enabled
    /// account, or `nil` when no such account exists. Runner construction mirrors
    /// `SessionWakeCLI.makeRuntime` so the app watcher and the CLI behave the
    /// same. `permissionMode`/`bypassAcknowledged`/`prompt` are captured by value
    /// (they are `Sendable`) to keep the `@Sendable` runner factory clean.
    private func resolvedRuntime() -> WakeProviderRuntime? {
        let mode = store.permissionMode
        let bypass = store.bypassAcknowledged
        let prompt = store.prompt

        switch store.wakeProvider {
        case .claude:
            guard let id = store.wakeAccountID,
                  let account = accounts.enabledAccounts.first(where: { $0.id == id }) else { return nil }
            return ClaudeWakeRuntime(account: account) { runnerAccount in
                WakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypass,
                    prompt: prompt
                )
            }
        case .codex:
            guard let id = store.wakeCodexAccountID,
                  let account = codexAccounts.enabledAccounts.first(where: { $0.id == id }) else { return nil }
            return CodexWakeRuntime(account: account) { runnerAccount in
                CodexWakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypass,
                    prompt: prompt
                )
            }
        }
    }

    /// The active provider's selected-account directory (Claude config dir or
    /// Codex CODEX_HOME), or `nil` when nothing enabled is selected.
    private func activeAccountDirectory() -> String? {
        switch store.wakeProvider {
        case .claude:
            guard let id = store.wakeAccountID else { return nil }
            return accounts.enabledAccounts.first(where: { $0.id == id })?.configDirectory
        case .codex:
            guard let id = store.wakeCodexAccountID else { return nil }
            return codexAccounts.enabledAccounts.first(where: { $0.id == id })?.homeDirectory
        }
    }

    private func startWatching(runtime: WakeProviderRuntime) {
        guard watchTask == nil else { return }
        let lifetimeLock = makeLifetimeLock()
        switch lifetimeLock.acquire() {
        case .acquired:
            localLifetimeLock = lifetimeLock
        case let .contended(holder):
            let suffix = holder.map { " (\($0.shortDescription))" } ?? ""
            status.update(state: .failed(reason: "Another Session Wake holder is active\(suffix)."))
            return
        case let .legacyHeld(guidance):
            status.update(state: .failed(reason: guidance))
            return
        case let .unavailable(reason):
            status.update(state: .failed(reason: "Wake lock unavailable: \(reason)"))
            return
        }

        status.updateBackgroundExecution(.inApp)
        let bounds = store.bounds
        // The factory seam still takes a runner (used by the concrete coordinator
        // init); the runtime supplies the real per-launch runner via makeRunner.
        let runner = runtime.makeRunner()
        let interval = rescanInterval
        let make = makeWatcher
        let publishedStatus = status

        watchTask = Task {
            while !Task.isCancelled {
                let watcher = make(runner, bounds) { state in
                    Task { @MainActor in publishedStatus.update(state: state) }
                }
                await watcher.start(runtime: runtime)
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
        let task = watchTask
        let lifetimeLock = localLifetimeLock
        task?.cancel()
        watchTask = nil
        localLifetimeLock = nil
        Task { [weak self] in
            await task?.value
            lifetimeLock?.release()
            self?.status.update(state: .off)
        }
    }

    // MARK: - Managed background agent

    private func saveAgentConfiguration(account: ClaudeCodeAccount?) {
        let notificationsAllowed = store.notifyOnCompletion
            && notificationPreferences.isEnabled
            && providerVisibility.isEnabled(.claudeCode)
        agentStateStore.saveConfiguration(
            SessionWakeAgentConfiguration(
                featureEnabled: store.featureEnabled,
                isArmed: store.isOn && account != nil,
                provider: .claude,
                accountDirectory: account?.configDirectory,
                permissionMode: store.permissionMode,
                bypassAcknowledged: store.bypassAcknowledged,
                prompt: store.prompt,
                notifyOnCompletion: notificationsAllowed,
                maxSessionsPerRun: store.maxSessionsPerRun,
                maxTurns: store.maxTurns
            )
        )
    }

    private func registerAgentIfNeeded() {
        switch agent.currentStatus() {
        case .enabled:
            status.updateBackgroundExecution(.active)
        case .requiresApproval:
            status.updateBackgroundExecution(.requiresApproval)
        case .notRegistered, .notFound, .unknown:
            do {
                try agent.register()
                refreshAgentRegistrationStatus()
            } catch {
                status.updateBackgroundExecution(.failed("Couldn't start the background watcher."))
                status.update(
                    state: .failed(reason: "Background watcher registration failed: \(error.localizedDescription)")
                )
                store.setOn(false)
                saveAgentConfiguration(account: selectedAccount())
            }
        }
    }

    private func unregisterAgentIfNeeded() {
        guard usesBackgroundAgent else { return }
        switch agent.currentStatus() {
        case .notRegistered, .notFound:
            status.updateBackgroundExecution(.inactive)
        case .enabled, .requiresApproval, .unknown:
            do {
                try agent.unregister()
                status.updateBackgroundExecution(.inactive)
            } catch {
                // The shared `isArmed = false` configuration is the immediate
                // kill switch even when ServiceManagement cannot unregister.
                status.updateBackgroundExecution(.failed("Background registration could not be removed."))
            }
        }
    }

    private func startAgentMonitorIfNeeded() {
        guard usesBackgroundAgent, agentMonitorTask == nil else { return }
        agentMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.refreshAgentRegistrationStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refreshAgentRegistrationStatus() {
        guard usesBackgroundAgent else { return }
        switch agent.currentStatus() {
        case .enabled:
            if let record = agentStateStore.loadStatus(),
               Date().timeIntervalSince(record.heartbeat) < 10 {
                status.update(state: record.watcherState)
                status.updateBackgroundExecution(.active)
            } else {
                status.updateBackgroundExecution(store.isOn ? .starting : .inactive)
            }
        case .requiresApproval:
            status.updateBackgroundExecution(.requiresApproval)
        case .notRegistered, .notFound:
            status.updateBackgroundExecution(.inactive)
        case .unknown:
            status.updateBackgroundExecution(.failed("Background watcher status is unavailable."))
        }
    }
}
