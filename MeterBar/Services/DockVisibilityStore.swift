import Combine
import Foundation

/// Persists whether MeterBar shows an icon in the Dock.
///
/// MeterBar always keeps its menu bar (status bar) item regardless of this
/// setting. This flag only controls the Dock icon, which the app delegate
/// applies by switching `NSApplication.ActivationPolicy` between `.regular`
/// (Dock icon shown) and `.accessory` (menu bar only).
final class DockVisibilityStore: ObservableObject {
    static let shared = DockVisibilityStore()

    /// `true` shows the Dock icon (`.regular`); `false` hides it (`.accessory`).
    @Published private(set) var showInDock: Bool

    private let userDefaults: UserDefaults
    private let storageKey = StorageKeys.showInDock

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if userDefaults.object(forKey: storageKey) == nil {
            // Default to showing in the Dock so the change is non-destructive
            // for existing installs; users opt into hiding it.
            showInDock = true
        } else {
            showInDock = userDefaults.bool(forKey: storageKey)
        }
    }

    func setShowInDock(_ show: Bool) {
        guard show != showInDock else { return }
        showInDock = show
        userDefaults.set(show, forKey: storageKey)
    }
}
