import Combine
import Foundation

/// Persists Session Wake preferences and enforces the safety toggle rules.
///
/// The store deliberately separates two concepts the UI must never conflate:
/// `featureEnabled` (the user wants the feature at all) and `watcherArmed`
/// (the watcher should be actively running now). Arming requires the feature on
/// *and* a first-enable acknowledgement; permission bypass requires its own
/// separate acknowledgement. The wake account is always explicit and is never
/// inferred from account order or recent activity.
final class SessionWakeSettingsStore: ObservableObject {
    static let shared = SessionWakeSettingsStore()

    @Published private(set) var featureEnabled: Bool
    @Published private(set) var watcherArmed: Bool
    @Published private(set) var wakeAccountID: UUID?
    @Published private(set) var firstEnableAcknowledged: Bool
    @Published private(set) var bypassAcknowledged: Bool
    @Published private(set) var permissionMode: WakePermissionMode
    @Published var prompt: String
    @Published var notifyOnCompletion: Bool
    @Published private(set) var maxSessionsPerRun: Int
    @Published private(set) var maxTurns: Int

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        featureEnabled = userDefaults.bool(forKey: StorageKeys.sessionWakeFeatureEnabled)
        watcherArmed = userDefaults.bool(forKey: StorageKeys.sessionWakeWatcherArmed)
        wakeAccountID = userDefaults.string(forKey: StorageKeys.sessionWakeAccountID).flatMap(UUID.init(uuidString:))
        firstEnableAcknowledged = userDefaults.bool(forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
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

        // Invariant: the watcher can never be armed while the feature is off.
        if !featureEnabled && watcherArmed {
            watcherArmed = false
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

    /// Whether the watcher may be armed given current acknowledgements.
    var canArmWatcher: Bool {
        featureEnabled && firstEnableAcknowledged && (permissionMode == .safe || bypassAcknowledged)
    }

    // MARK: - Mutations

    /// Turning the feature off forces the watcher off too (master switch).
    func setFeatureEnabled(_ enabled: Bool) {
        guard enabled != featureEnabled else { return }
        featureEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKeys.sessionWakeFeatureEnabled)
        if !enabled {
            forceWatcherOff()
        }
    }

    /// Arming is refused unless `canArmWatcher`. Disarming always succeeds.
    func setWatcherArmed(_ armed: Bool) {
        if armed {
            guard canArmWatcher else { return }
        }
        guard armed != watcherArmed else { return }
        watcherArmed = armed
        userDefaults.set(armed, forKey: StorageKeys.sessionWakeWatcherArmed)
    }

    func setWakeAccountID(_ id: UUID?) {
        guard id != wakeAccountID else { return }
        wakeAccountID = id
        if let id {
            userDefaults.set(id.uuidString, forKey: StorageKeys.sessionWakeAccountID)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.sessionWakeAccountID)
        }
    }

    func setFirstEnableAcknowledged(_ acknowledged: Bool) {
        guard acknowledged != firstEnableAcknowledged else { return }
        firstEnableAcknowledged = acknowledged
        userDefaults.set(acknowledged, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        if !acknowledged { forceWatcherOff() }
    }

    func setPermissionMode(_ mode: WakePermissionMode) {
        guard mode != permissionMode else { return }
        permissionMode = mode
        userDefaults.set(mode.rawValue, forKey: StorageKeys.sessionWakePermissionMode)
        // Switching to bypass without acknowledgement must not leave the watcher
        // armed under an unacknowledged posture.
        if mode == .bypass && !bypassAcknowledged { forceWatcherOff() }
    }

    func setBypassAcknowledged(_ acknowledged: Bool) {
        guard acknowledged != bypassAcknowledged else { return }
        bypassAcknowledged = acknowledged
        userDefaults.set(acknowledged, forKey: StorageKeys.sessionWakeBypassAcknowledged)
        if !acknowledged && permissionMode == .bypass { forceWatcherOff() }
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
    /// account disappeared, clear it and disarm the watcher — automation must
    /// never silently retarget another account.
    func reconcileAccounts(available ids: [UUID]) {
        guard let selected = wakeAccountID else { return }
        if !ids.contains(selected) {
            setWakeAccountID(nil)
            forceWatcherOff()
        }
    }

    private func forceWatcherOff() {
        guard watcherArmed else { return }
        watcherArmed = false
        userDefaults.set(false, forKey: StorageKeys.sessionWakeWatcherArmed)
    }
}
