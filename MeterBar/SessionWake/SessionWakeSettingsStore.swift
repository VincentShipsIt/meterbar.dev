import Combine
import Foundation
import MeterBarShared

/// Persists Session Wake preferences behind a user ON/OFF switch and a master
/// feature kill-switch.
///
/// `isOn` is the one control: when on, the watcher polls the selected account's
/// session limits and resumes blocked sessions after reset; when off, nothing
/// runs. The first time it is turned on, `firstRunAcknowledged` gates a one-time
/// confirmation (the UI shows a sheet); after that it is a plain toggle.
/// Permission bypass still requires its own separate acknowledgement, and the
/// wake account is always explicit — never inferred from order or activity.
final class SessionWakeSettingsStore: ObservableObject {
    static let shared = SessionWakeSettingsStore()

    @Published private(set) var featureEnabled: Bool
    @Published private(set) var isOn: Bool
    @Published private(set) var wakeProvider: WakeProvider
    @Published private(set) var wakeAccountID: UUID?
    @Published private(set) var wakeCodexAccountID: UUID?
    @Published private(set) var firstRunAcknowledged: Bool
    @Published private(set) var bypassAcknowledged: Bool
    @Published private(set) var permissionMode: WakePermissionMode
    @Published var prompt: String
    @Published var notifyOnCompletion: Bool
    @Published private(set) var maxSessionsPerRun: Int
    @Published private(set) var maxTurns: Int
    @Published private(set) var eventHookConfiguration: WakeEventHookConfiguration

    private let userDefaults: UserDefaults
    private let agentStateStore: SessionWakeAgentStateStore?

    init(
        userDefaults: UserDefaults = .standard,
        agentStateStore: SessionWakeAgentStateStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.agentStateStore = agentStateStore
            ?? (userDefaults === UserDefaults.standard ? SessionWakeAgentStateStore() : nil)
        if userDefaults.object(forKey: StorageKeys.sessionWakeFeatureEnabled) == nil {
            // Session Wake shipped before this key was wired. Preserve that
            // behavior for existing installs; an explicit false is the master
            // emergency-off switch.
            featureEnabled = true
        } else {
            featureEnabled = userDefaults.bool(forKey: StorageKeys.sessionWakeFeatureEnabled)
        }
        isOn = userDefaults.bool(forKey: StorageKeys.sessionWakeWatcherArmed)
        wakeProvider = userDefaults.string(forKey: StorageKeys.sessionWakeProvider)
            .flatMap(WakeProvider.init(rawValue:)) ?? .claude
        wakeAccountID = userDefaults.string(forKey: StorageKeys.sessionWakeAccountID).flatMap(UUID.init(uuidString:))
        wakeCodexAccountID = userDefaults.string(forKey: StorageKeys.sessionWakeCodexAccountID)
            .flatMap(UUID.init(uuidString:))
        firstRunAcknowledged = userDefaults.bool(forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        bypassAcknowledged = userDefaults.bool(forKey: StorageKeys.sessionWakeBypassAcknowledged)
        permissionMode = userDefaults.string(forKey: StorageKeys.sessionWakePermissionMode)
            .flatMap(WakePermissionMode.init(rawValue:)) ?? .safe
        prompt = userDefaults.string(forKey: StorageKeys.sessionWakePrompt) ?? WakeCommandBuilder.defaultPrompt
        if userDefaults.object(forKey: StorageKeys.sessionWakeNotifyOnCompletion) == nil {
            notifyOnCompletion = true
        } else {
            notifyOnCompletion = userDefaults.bool(forKey: StorageKeys.sessionWakeNotifyOnCompletion)
        }
        let storedSessions = userDefaults.object(forKey: StorageKeys.sessionWakeMaxSessionsPerRun) as? Int
        maxSessionsPerRun = storedSessions ?? WakeBounds.default.maxSessionsPerRun
        let storedTurns = userDefaults.object(forKey: StorageKeys.sessionWakeMaxTurns) as? Int
        maxTurns = storedTurns ?? WakeBounds.default.maxTurns
        eventHookConfiguration = userDefaults.data(forKey: StorageKeys.sessionWakeEventHooks)
            .flatMap { try? JSONDecoder().decode(WakeEventHookConfiguration.self, from: $0) }
            ?? .disabled

        // Invariant: never persist "on" while the master switch is off or
        // without the remaining preconditions still holding.
        if isOn && !canTurnOn {
            isOn = false
            userDefaults.set(false, forKey: StorageKeys.sessionWakeWatcherArmed)
        }

        if userDefaults === UserDefaults.standard {
            syncSharedFeatureFlag()
            syncAgentControlFlags()
        }
    }

    /// Bounds derived from persisted prefs, always validated/clamped.
    var bounds: WakeBounds {
        WakeBounds(
            pollInterval: WakeBounds.default.pollInterval,
            bufferAfterReset: WakeBounds.default.bufferAfterReset,
            gapBetweenSessions: WakeBounds.default.gapBetweenSessions,
            perSessionTimeout: WakeBounds.default.perSessionTimeout,
            maxTurns: maxTurns,
            maxSessionsPerRun: maxSessionsPerRun,
            maxUnknownPolls: WakeBounds.default.maxUnknownPolls
        )
    }

    /// The explicitly selected account id for the active provider. Session Wake
    /// keeps one selection per provider so switching providers never silently
    /// retargets automation at whatever account the other provider had.
    var activeAccountID: UUID? {
        switch wakeProvider {
        case .claude: return wakeAccountID
        case .codex: return wakeCodexAccountID
        }
    }

    /// Whether the switch may be turned on right now: an explicit account for the
    /// active provider and, for bypass mode, its separate acknowledgement.
    var canTurnOn: Bool {
        featureEnabled && activeAccountID != nil && (permissionMode == .safe || bypassAcknowledged)
    }

    /// True when turning on should first show the one-time confirmation.
    var needsFirstRunConfirmation: Bool {
        !firstRunAcknowledged
    }

    // MARK: - Mutations

    /// The master kill-switch. Disabling the feature immediately clears live
    /// watcher intent and is mirrored to the app-group domain used by the CLI.
    func setFeatureEnabled(_ enabled: Bool) {
        guard enabled != featureEnabled else { return }
        featureEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKeys.sessionWakeFeatureEnabled)
        if userDefaults === UserDefaults.standard {
            syncSharedFeatureFlag()
        }
        if !enabled {
            forceOff()
        }
        syncAgentControlFlags()
    }

    /// Turn the watcher on or off. Turning on is refused unless `canTurnOn` and
    /// the first-run confirmation has been acknowledged; turning off always
    /// succeeds (kill switch).
    func setOn(_ on: Bool) {
        if on {
            guard canTurnOn, firstRunAcknowledged else { return }
        }
        guard on != isOn else { return }
        isOn = on
        userDefaults.set(on, forKey: StorageKeys.sessionWakeWatcherArmed)
        syncAgentControlFlags()
    }

    /// Complete the one-time confirmation and turn on in a single step (what the
    /// first-run sheet's confirm button calls).
    func acknowledgeFirstRunAndTurnOn() {
        if !firstRunAcknowledged {
            firstRunAcknowledged = true
            userDefaults.set(true, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        }
        setOn(true)
    }

    /// Switch the active wake provider. Only one provider watches at a time (the
    /// single-toggle model); flipping it disarms so automation never keeps
    /// running against the previously selected provider/account pair.
    func setWakeProvider(_ provider: WakeProvider) {
        guard provider != wakeProvider else { return }
        wakeProvider = provider
        userDefaults.set(provider.rawValue, forKey: StorageKeys.sessionWakeProvider)
        forceOff()
    }

    func setWakeAccountID(_ id: UUID?) {
        guard id != wakeAccountID else { return }
        wakeAccountID = id
        if let id {
            userDefaults.set(id.uuidString, forKey: StorageKeys.sessionWakeAccountID)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.sessionWakeAccountID)
        }
        // Any change of the wake target disarms the watcher. Otherwise a live
        // watcher would stay bound to the *old* account (the controller only
        // starts a watch when none is running), and automation must never keep
        // running against — or silently retarget to — an account the user did
        // not just explicitly arm. Re-arming with the new account is one toggle.
        forceOff()
    }

    /// The Codex analogue of `setWakeAccountID`. Same disarm invariant: changing
    /// the Codex wake target turns the watcher off.
    func setWakeCodexAccountID(_ id: UUID?) {
        guard id != wakeCodexAccountID else { return }
        wakeCodexAccountID = id
        if let id {
            userDefaults.set(id.uuidString, forKey: StorageKeys.sessionWakeCodexAccountID)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.sessionWakeCodexAccountID)
        }
        forceOff()
    }

    func setPermissionMode(_ mode: WakePermissionMode) {
        guard mode != permissionMode else { return }
        permissionMode = mode
        userDefaults.set(mode.rawValue, forKey: StorageKeys.sessionWakePermissionMode)
        // Bypass without acknowledgement must not leave the watcher on.
        if mode == .bypass && !bypassAcknowledged { forceOff() }
    }

    func setBypassAcknowledged(_ acknowledged: Bool) {
        guard acknowledged != bypassAcknowledged else { return }
        bypassAcknowledged = acknowledged
        userDefaults.set(acknowledged, forKey: StorageKeys.sessionWakeBypassAcknowledged)
        if !acknowledged && permissionMode == .bypass { forceOff() }
    }

    func setMaxSessionsPerRun(_ value: Int) {
        let clamped = value.clamped(to: WakeBounds.sessionsRange)
        guard clamped != maxSessionsPerRun else { return }
        maxSessionsPerRun = clamped
        userDefaults.set(clamped, forKey: StorageKeys.sessionWakeMaxSessionsPerRun)
    }

    func setMaxTurns(_ value: Int) {
        let clamped = value.clamped(to: WakeBounds.maxTurnsRange)
        guard clamped != maxTurns else { return }
        maxTurns = clamped
        userDefaults.set(clamped, forKey: StorageKeys.sessionWakeMaxTurns)
    }

    // MARK: - Event hooks

    func setHookExecutablePath(_ path: String) {
        guard path != eventHookConfiguration.executablePath else { return }
        eventHookConfiguration.executablePath = path
        if !eventHookConfiguration.isConfigured {
            eventHookConfiguration.enabledEvents.removeAll()
        }
        persistEventHooks()
    }

    func addHookArgument() {
        eventHookConfiguration.arguments.append("")
        persistEventHooks()
    }

    func setHookArgument(_ value: String, at index: Int) {
        guard eventHookConfiguration.arguments.indices.contains(index),
              eventHookConfiguration.arguments[index] != value else { return }
        eventHookConfiguration.arguments[index] = value
        persistEventHooks()
    }

    func removeHookArgument(at index: Int) {
        guard eventHookConfiguration.arguments.indices.contains(index) else { return }
        eventHookConfiguration.arguments.remove(at: index)
        persistEventHooks()
    }

    func setHookEnabled(_ enabled: Bool, for event: WakeEventHookEvent) {
        if enabled {
            guard eventHookConfiguration.isConfigured else { return }
            eventHookConfiguration.enabledEvents.insert(event)
        } else {
            eventHookConfiguration.enabledEvents.remove(event)
        }
        persistEventHooks()
    }

    /// Reconcile with the currently available Claude accounts. If the selected
    /// Claude wake account disappeared, clear it and turn off — automation must
    /// never silently retarget another account.
    func reconcileAccounts(available ids: [UUID]) {
        guard let selected = wakeAccountID else { return }
        if !ids.contains(selected) {
            setWakeAccountID(nil) // also forces off
        }
    }

    /// The Codex analogue of `reconcileAccounts`.
    func reconcileCodexAccounts(available ids: [UUID]) {
        guard let selected = wakeCodexAccountID else { return }
        if !ids.contains(selected) {
            setWakeCodexAccountID(nil) // also forces off
        }
    }

    /// Mirror the active provider's selected account location to the app-group
    /// domain the bundled `meterbar wake` CLI reads, so the CLI targets the same
    /// account the app watches — Claude's config dir under
    /// `SessionWakeAccountConfigDir`, Codex's CODEX_HOME under
    /// `SessionWakeCodexHomeDir`. The inactive provider's key is cleared so a
    /// stale value never leaks across a provider switch. A `nil`/empty directory
    /// (e.g. the default profile) clears the key and lets the CLI fall back to
    /// its own default resolution.
    ///
    /// Only the production standard-suite store mirrors; test suites stay
    /// isolated (same guard as `syncSharedFeatureFlag`) so unit tests never
    /// write into the real app group.
    func syncSharedWakeTarget(directory: String?) {
        guard userDefaults === UserDefaults.standard,
              let shared = UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) else {
            return
        }
        let activeKey: String
        let inactiveKey: String
        switch wakeProvider {
        case .claude:
            activeKey = SessionWakeCLI.sharedAccountConfigKey
            inactiveKey = SessionWakeCLI.sharedCodexHomeKey
        case .codex:
            activeKey = SessionWakeCLI.sharedCodexHomeKey
            inactiveKey = SessionWakeCLI.sharedAccountConfigKey
        }
        let trimmed = directory?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            shared.set(trimmed, forKey: activeKey)
        } else {
            shared.removeObject(forKey: activeKey)
        }
        shared.removeObject(forKey: inactiveKey)
    }

    private func forceOff() {
        guard isOn else { return }
        isOn = false
        userDefaults.set(false, forKey: StorageKeys.sessionWakeWatcherArmed)
        syncAgentControlFlags()
    }

    private func syncSharedFeatureFlag() {
        UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)?
            .set(featureEnabled, forKey: SessionWakeCLI.sharedFeatureEnabledKey)
    }

    private func persistEventHooks() {
        guard let data = try? JSONEncoder().encode(eventHookConfiguration) else { return }
        userDefaults.set(data, forKey: StorageKeys.sessionWakeEventHooks)
    }

    /// Synchronous kill-switch propagation. The controller writes the complete
    /// configuration, but turning Session Wake off must reach an already-running
    /// agent before the next Combine/run-loop reconciliation (including an
    /// immediate app quit).
    private func syncAgentControlFlags() {
        guard let agentStateStore,
              let configuration = agentStateStore.loadConfiguration() else { return }
        agentStateStore.saveConfiguration(
            configuration.withControlFlags(featureEnabled: featureEnabled, isArmed: isOn)
        )
    }
}
