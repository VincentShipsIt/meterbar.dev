import Combine
import Foundation

/// Persists the user's notification preferences: the global on/off switch and
/// the warning/critical band thresholds.
///
/// Mirrors `DockVisibilityStore` / `ProviderVisibilityStore` — a small
/// `ObservableObject` backed by `UserDefaults`, injectable for tests. Defaults
/// preserve the pre-preferences behavior (notifications on, warn at `.critical`,
/// alert at `.exhausted`), so existing installs see no change until they opt in.
final class NotificationPreferencesStore: ObservableObject {
    static let shared = NotificationPreferencesStore()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var warningThreshold: NotificationThreshold
    @Published private(set) var criticalThreshold: NotificationThreshold

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if userDefaults.object(forKey: StorageKeys.notificationsEnabled) == nil {
            isEnabled = true
        } else {
            isEnabled = userDefaults.bool(forKey: StorageKeys.notificationsEnabled)
        }

        warningThreshold = userDefaults.string(forKey: StorageKeys.notificationWarningThreshold)
            .flatMap(NotificationThreshold.init(rawValue:)) ?? .critical
        criticalThreshold = userDefaults.string(forKey: StorageKeys.notificationCriticalThreshold)
            .flatMap(NotificationThreshold.init(rawValue:)) ?? .exhausted
    }

    /// The current preferences as a pure value, for handing to `NotificationDecider`.
    var preferences: NotificationPreferences {
        NotificationPreferences(
            isEnabled: isEnabled,
            warningThreshold: warningThreshold,
            criticalThreshold: criticalThreshold
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKeys.notificationsEnabled)
    }

    func setWarningThreshold(_ threshold: NotificationThreshold) {
        guard threshold != warningThreshold else { return }
        warningThreshold = threshold
        userDefaults.set(threshold.rawValue, forKey: StorageKeys.notificationWarningThreshold)
    }

    func setCriticalThreshold(_ threshold: NotificationThreshold) {
        guard threshold != criticalThreshold else { return }
        criticalThreshold = threshold
        userDefaults.set(threshold.rawValue, forKey: StorageKeys.notificationCriticalThreshold)
    }
}
