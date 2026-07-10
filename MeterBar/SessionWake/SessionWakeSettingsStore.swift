import Combine
import Foundation

/// Persists Session Wake control intent (issue #98).
///
/// Deliberately separates two axes the epic (#94) requires to stay independent:
///
/// - **Feature enablement** (`isFeatureEnabled`) — whether the user has opted in
///   at all. When off, no background discovery or resume may run.
/// - **Watcher intent** (`isWatcherArmed`) — whether the quota watcher is live.
///   Turning the feature off forces the watcher off; the watcher can never be
///   armed while the feature is off, no account is selected, or the first-enable
///   acknowledgement is missing.
///
/// The selected `wakeAccountID` is **explicit** and persisted — it is never
/// inferred from account order, recent menu-bar activity, or
/// `~/.claude-active-account`. Mirrors the small `ObservableObject` +
/// `UserDefaults` pattern of `NotificationPreferencesStore` /
/// `ProviderVisibilityStore`, injectable for tests.
final class SessionWakeSettingsStore: ObservableObject {
    static let shared = SessionWakeSettingsStore()

    @Published private(set) var isFeatureEnabled: Bool
    @Published private(set) var isWatcherArmed: Bool
    @Published private(set) var wakeAccountID: UUID?
    @Published private(set) var hasAcknowledgedFirstEnable: Bool
    @Published private(set) var hasAcknowledgedPermissionBypass: Bool
    @Published private(set) var notifyOnCompletion: Bool
    @Published private(set) var notifyOnWatchStart: Bool

    private let userDefaults: UserDefaults

    /// Internal (not private) so tests can construct an instance backed by an
    /// isolated `UserDefaults` suite; production code uses `shared`.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Read into locals first so the final `isWatcherArmed` assignment does
        // not reference any not-yet-initialized `@Published` property (Swift's
        // definite-initialization rejects that with property wrappers).
        let featureEnabled = userDefaults.bool(forKey: StorageKeys.sessionWakeFeatureEnabled)
        let armed = userDefaults.bool(forKey: StorageKeys.sessionWakeWatcherArmed)
        let acknowledged = userDefaults.bool(forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
        let accountID = userDefaults.string(forKey: StorageKeys.sessionWakeAccountID)
            .flatMap(UUID.init(uuidString:))

        isFeatureEnabled = featureEnabled
        hasAcknowledgedFirstEnable = acknowledged
        hasAcknowledgedPermissionBypass = userDefaults
            .bool(forKey: StorageKeys.sessionWakePermissionBypassAcknowledged)
        wakeAccountID = accountID

        // Notification defaults preserve "on" when the user has never chosen.
        notifyOnCompletion = userDefaults
            .object(forKey: StorageKeys.sessionWakeNotifyOnCompletion) == nil
            ? true
            : userDefaults.bool(forKey: StorageKeys.sessionWakeNotifyOnCompletion)
        notifyOnWatchStart = userDefaults
            .object(forKey: StorageKeys.sessionWakeNotifyOnWatchStart) == nil
            ? true
            : userDefaults.bool(forKey: StorageKeys.sessionWakeNotifyOnWatchStart)

        // Fail safe on load: the watcher can only be armed if every precondition
        // holds. A relaunch with the feature disabled (or no account) must never
        // resurrect a live watcher.
        let shouldArm = armed && Self.canArmWatcher(
            featureEnabled: featureEnabled,
            accountID: accountID,
            acknowledged: acknowledged
        )
        isWatcherArmed = shouldArm
        if shouldArm != armed {
            userDefaults.set(shouldArm, forKey: StorageKeys.sessionWakeWatcherArmed)
        }
    }

    // MARK: Derived

    /// Whether arming the watcher is currently permitted. Surfaced so the UI can
    /// disable the toggle rather than silently swallow an invalid arm request.
    var canArmWatcher: Bool {
        Self.canArmWatcher(
            featureEnabled: isFeatureEnabled,
            accountID: wakeAccountID,
            acknowledged: hasAcknowledgedFirstEnable
        )
    }

    // MARK: Feature enablement

    /// Enables or disables the feature. Enabling is gated on the first-enable
    /// acknowledgement — call `acknowledgeFirstEnable()` first (the UI presents
    /// the safety sheet). Disabling always succeeds and forces the watcher off.
    func setFeatureEnabled(_ enabled: Bool) {
        if enabled {
            guard hasAcknowledgedFirstEnable else { return }
            guard !isFeatureEnabled else { return }
            isFeatureEnabled = true
            persist(true, forKey: StorageKeys.sessionWakeFeatureEnabled)
        } else {
            guard isFeatureEnabled || isWatcherArmed else { return }
            isFeatureEnabled = false
            persist(false, forKey: StorageKeys.sessionWakeFeatureEnabled)
            // Master-off cancels watcher intent (issue #98 acceptance criterion).
            forceWatcherOff()
        }
    }

    /// Records the first-enable safety acknowledgement. Idempotent.
    func acknowledgeFirstEnable() {
        guard !hasAcknowledgedFirstEnable else { return }
        hasAcknowledgedFirstEnable = true
        persist(true, forKey: StorageKeys.sessionWakeFirstEnableAcknowledged)
    }

    // MARK: Watcher intent

    /// Arms or disarms the watcher. Arming is rejected (no-op) unless the feature
    /// is enabled, an account is selected, and the first-enable acknowledgement
    /// is present. Disarming always succeeds.
    func setWatcherArmed(_ armed: Bool) {
        if armed {
            guard canArmWatcher, !isWatcherArmed else { return }
            isWatcherArmed = true
            persist(true, forKey: StorageKeys.sessionWakeWatcherArmed)
        } else {
            guard isWatcherArmed else { return }
            isWatcherArmed = false
            persist(false, forKey: StorageKeys.sessionWakeWatcherArmed)
        }
    }

    // MARK: Account selection

    /// Explicitly selects (or clears) the wake account. Changing the selection
    /// while the watcher is armed safely disarms it, so discovery/quota/execution
    /// never straddle two accounts (issue #98 acceptance criterion).
    func selectWakeAccount(_ id: UUID?) {
        guard id != wakeAccountID else { return }
        wakeAccountID = id
        if let id {
            persist(id.uuidString, forKey: StorageKeys.sessionWakeAccountID)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.sessionWakeAccountID)
        }
        // A changed or cleared account invalidates any in-flight watch.
        forceWatcherOff()
    }

    /// Reconciles the selection against the accounts that currently exist. If the
    /// selected account was removed, the selection is cleared and the watcher is
    /// suspended. Called whenever the account list changes.
    func reconcile(availableAccountIDs: Set<UUID>) {
        guard let id = wakeAccountID, !availableAccountIDs.contains(id) else { return }
        wakeAccountID = nil
        userDefaults.removeObject(forKey: StorageKeys.sessionWakeAccountID)
        forceWatcherOff()
    }

    // MARK: Permission bypass

    func setPermissionBypassAcknowledged(_ acknowledged: Bool) {
        guard acknowledged != hasAcknowledgedPermissionBypass else { return }
        hasAcknowledgedPermissionBypass = acknowledged
        persist(acknowledged, forKey: StorageKeys.sessionWakePermissionBypassAcknowledged)
    }

    // MARK: Notification preferences

    func setNotifyOnCompletion(_ enabled: Bool) {
        guard enabled != notifyOnCompletion else { return }
        notifyOnCompletion = enabled
        persist(enabled, forKey: StorageKeys.sessionWakeNotifyOnCompletion)
    }

    func setNotifyOnWatchStart(_ enabled: Bool) {
        guard enabled != notifyOnWatchStart else { return }
        notifyOnWatchStart = enabled
        persist(enabled, forKey: StorageKeys.sessionWakeNotifyOnWatchStart)
    }

    // MARK: Private

    private func forceWatcherOff() {
        guard isWatcherArmed else { return }
        isWatcherArmed = false
        persist(false, forKey: StorageKeys.sessionWakeWatcherArmed)
    }

    private static func canArmWatcher(featureEnabled: Bool, accountID: UUID?, acknowledged: Bool) -> Bool {
        featureEnabled && accountID != nil && acknowledged
    }

    private func persist(_ value: Bool, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    private func persist(_ value: String, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }
}
