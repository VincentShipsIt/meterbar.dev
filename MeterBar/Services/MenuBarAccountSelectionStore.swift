import Combine
import Foundation

// MARK: - MenuBarAccountSelectionOutcome

/// Result of a selection change, so the UI can explain a rejection instead of
/// silently dropping the account the user just picked.
nonisolated enum MenuBarAccountSelectionOutcome: Equatable, Sendable {
    case updated
    case unchanged
    /// The cap was already reached; the associated value is that cap.
    case rejectedLimit(Int)
}

// MARK: - MenuBarAccountSelectionStore

/// Persists which accounts own a menu-bar status item (issue #266).
///
/// Defaults reproduce the pre-#266 menu bar exactly: `.single` mode, no selected
/// accounts, no merged binding — so an existing installation that never opts in
/// sees no change after upgrading.
final class MenuBarAccountSelectionStore: ObservableObject {
    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        mode = userDefaults.string(forKey: StorageKeys.menuBarAccountDisplayMode)
            .flatMap(MenuBarAccountDisplayMode.init(rawValue:)) ?? .single
        selectedAccountKeys = Self.normalizedSelection(
            userDefaults.stringArray(forKey: StorageKeys.menuBarSelectedAccountKeys) ?? []
        )
        mergedAccountKey = userDefaults.string(forKey: StorageKeys.menuBarMergedAccountKey)
            .flatMap(Self.normalizedKey)
    }

    // MARK: Internal

    static let shared = MenuBarAccountSelectionStore()

    @Published private(set) var mode: MenuBarAccountDisplayMode
    @Published private(set) var selectedAccountKeys: [String]
    @Published private(set) var mergedAccountKey: String?

    /// Documented cap on concurrent status items.
    var itemLimit: Int { MenuBarStatusItemPlanner.maximumConcurrentItems }

    func setMode(_ newMode: MenuBarAccountDisplayMode) {
        guard newMode != mode else { return }
        mode = newMode
        userDefaults.set(newMode.rawValue, forKey: StorageKeys.menuBarAccountDisplayMode)
    }

    func isSelected(_ key: String) -> Bool {
        selectedAccountKeys.contains(key)
    }

    @discardableResult
    func select(_ key: String) -> MenuBarAccountSelectionOutcome {
        guard let normalized = Self.normalizedKey(key) else { return .unchanged }
        guard !selectedAccountKeys.contains(normalized) else { return .unchanged }
        guard selectedAccountKeys.count < itemLimit else { return .rejectedLimit(itemLimit) }
        persistSelection(selectedAccountKeys + [normalized])
        return .updated
    }

    @discardableResult
    func deselect(_ key: String) -> MenuBarAccountSelectionOutcome {
        guard let normalized = Self.normalizedKey(key),
              selectedAccountKeys.contains(normalized) else { return .unchanged }
        persistSelection(selectedAccountKeys.filter { $0 != normalized })
        return .updated
    }

    @discardableResult
    func setSelected(_ isSelected: Bool, for key: String) -> MenuBarAccountSelectionOutcome {
        isSelected ? select(key) : deselect(key)
    }

    func setMergedAccountKey(_ key: String?) {
        let normalized = key.flatMap(Self.normalizedKey)
        guard normalized != mergedAccountKey else { return }
        mergedAccountKey = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: StorageKeys.menuBarMergedAccountKey)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.menuBarMergedAccountKey)
        }
    }

    // MARK: Private

    private let userDefaults: UserDefaults

    nonisolated private static func normalizedKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persisted defaults can be hand-edited or written by a future build, so a
    /// stored list is de-duplicated and capped before it can install items.
    nonisolated private static func normalizedSelection(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        let unique = keys
            .compactMap(normalizedKey)
            .filter { seen.insert($0).inserted }
        return Array(unique.prefix(MenuBarStatusItemPlanner.maximumConcurrentItems))
    }

    private func persistSelection(_ keys: [String]) {
        selectedAccountKeys = keys
        userDefaults.set(keys, forKey: StorageKeys.menuBarSelectedAccountKeys)
    }
}
