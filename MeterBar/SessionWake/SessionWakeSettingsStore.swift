import Combine
import Foundation

/// Persists Session Wake preferences behind a single ON/OFF switch.
///
/// `isOn` is the one control: when on, the watcher polls the selected account's
/// session limits and resumes blocked sessions after reset; when off, nothing
/// runs. The first time it is turned on, `firstRunAcknowledged` gates a one-time
/// confirmation (the UI shows a sheet); after that it is a plain toggle.
/// Permission bypass still requires its own separate acknowledgement, and the
/// wake account is always explicit — never inferred from order or activity.
final class SessionWakeSettingsStore: ObservableObject {
    static let shared = SessionWakeSettingsStore()

    @Published private(set) var isOn: Bool
    @Published private(set) var wakeAccountID: UUID?
    @Published private(set) var firstRunAcknowledged: Bool
    @Published private(set) var bypassAcknowledged: Bool
    @Published private(set) var permissionMode: WakePermissionMode
    @Published var prompt: String
    @Published var notifyOnCompletion: Bool
    @Published private(set) var maxSessionsPerRun: Int
    @Published private(set) var maxTurns: Int

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isOn = userDefaults.bool(forKey: StorageKeys.sessionWakeWatcherArmed)
        wakeAccountID = userDefaults.string(forKey: StorageKeys.sessionWakeAccountID).flatMap(UUID.init(uuidString:))
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

        // Invariant: never persist "on" without the preconditions still holding.
        if isOn && !canTurnOn {
            isOn = false
            userDefaults.set(false, forKey: StorageKeys.sessionWakeWatcherArmed)
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

    /// Whether the switch may be turned on right now: an explicit account and,
    /// for bypass mode, its separate acknowledgement.
    var canTurnOn: Bool {
        wakeAccountID != nil && (permissionMode == .safe || bypassAcknowledged)
    }

    /// True when turning on should first show the one-time confirmation.
    var needsFirstRunConfirmation: Bool {
        !firstRunAcknowledged
    }

    // MARK: - Mutations

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

    /// Reconcile with the currently available accounts. If the selected wake
    /// account disappeared, clear it and turn off — automation must never
    /// silently retarget another account.
    func reconcileAccounts(available ids: [UUID]) {
        guard let selected = wakeAccountID else { return }
        if !ids.contains(selected) {
            setWakeAccountID(nil) // also forces off
        }
    }

    private func forceOff() {
        guard isOn else { return }
        isOn = false
        userDefaults.set(false, forKey: StorageKeys.sessionWakeWatcherArmed)
    }
}
