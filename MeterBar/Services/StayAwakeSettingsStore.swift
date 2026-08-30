import Combine
import Foundation

/// Persists the user's explicit Stay Awake intent. Fresh installs are off.
final class StayAwakeSettingsStore: ObservableObject {
    static let shared = StayAwakeSettingsStore()

    @Published private(set) var isEnabled: Bool

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: StorageKeys.stayAwakeEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: StorageKeys.stayAwakeEnabled)
    }
}
