import Combine
import Foundation

nonisolated struct CodexAccount: Codable, Equatable, Identifiable, Sendable {
    static let defaultName = "Default CLI Profile"
    static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))

    static let defaultAccount = CodexAccount(
        id: Self.defaultID,
        name: Self.defaultName,
        homeDirectory: nil
    )

    let id: UUID
    var name: String
    var homeDirectory: String?
    var isEnabled: Bool

    init(id: UUID, name: String, homeDirectory: String?, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.homeDirectory = homeDirectory
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        homeDirectory = try container.decodeIfPresent(String.self, forKey: .homeDirectory)
        // Backward-compat: profiles persisted before the enable/disable flag
        // existed decode as enabled.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var isDefault: Bool { id == Self.defaultID }
}

final class CodexAccountStore: ObservableObject {
    static let shared = CodexAccountStore()

    @Published private(set) var customAccounts: [CodexAccount] = []
    @Published private(set) var defaultAccountName = CodexAccount.defaultName
    @Published private(set) var defaultAccountIsEnabled = true
    @Published private(set) var accountOrder: [UUID] = []

    private let userDefaults: UserDefaults

    var accounts: [CodexAccount] {
        orderedAccounts(from: [
            CodexAccount(
                id: CodexAccount.defaultID,
                name: defaultAccountName,
                homeDirectory: nil,
                isEnabled: defaultAccountIsEnabled
            )
        ] + customAccounts)
    }

    var enabledAccounts: [CodexAccount] {
        accounts.filter(\.isEnabled)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func addAccount(name: String, homeDirectory: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty else { return }

        let account = CodexAccount(
            id: UUID(),
            name: trimmedName,
            homeDirectory: (trimmedDirectory as NSString).standardizingPath
        )
        customAccounts.append(account)
        if !accountOrder.isEmpty {
            accountOrder.append(account.id)
            saveAccountOrder()
        }
        saveCustomAccounts()
    }

    func updateAccount(id: UUID, name: String, homeDirectory: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if id == CodexAccount.defaultID {
            guard trimmedName != defaultAccountName else { return }
            defaultAccountName = trimmedName
            saveDefaultAccountName()
            return
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }), let homeDirectory else { return }
        let trimmedDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else { return }

        var updated = customAccounts[index]
        updated.name = trimmedName
        updated.homeDirectory = (trimmedDirectory as NSString).standardizingPath
        guard updated != customAccounts[index] else { return }
        var updatedAccounts = customAccounts
        updatedAccounts[index] = updated
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func removeAccount(id: UUID) {
        guard id != CodexAccount.defaultID else { return }
        customAccounts.removeAll { $0.id == id }
        accountOrder.removeAll { $0 == id }
        saveAccountOrder()
        saveCustomAccounts()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        if id == CodexAccount.defaultID {
            guard enabled != defaultAccountIsEnabled else { return }
            defaultAccountIsEnabled = enabled
            saveDefaultAccountEnabled()
            return
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }),
              customAccounts[index].isEnabled != enabled else {
            return
        }
        var updatedAccounts = customAccounts
        updatedAccounts[index].isEnabled = enabled
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = accounts
        let movingIndexes = source.sorted()
        guard movingIndexes.allSatisfy({ ordered.indices.contains($0) }) else { return }

        let movingAccounts = movingIndexes.map { ordered[$0] }
        for index in movingIndexes.reversed() { ordered.remove(at: index) }
        let removedBeforeDestination = movingIndexes.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removedBeforeDestination, ordered.count))
        ordered.insert(contentsOf: movingAccounts, at: adjustedDestination)
        accountOrder = ordered.map(\.id)
        saveAccountOrder()
    }

    private func load() {
        if let name = userDefaults.string(forKey: StorageKeys.codexDefaultAccountName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            defaultAccountName = name
        }
        if userDefaults.object(forKey: StorageKeys.codexDefaultAccountEnabled) != nil {
            defaultAccountIsEnabled = userDefaults.bool(forKey: StorageKeys.codexDefaultAccountEnabled)
        }
        accountOrder = userDefaults.stringArray(forKey: StorageKeys.codexAccountOrder)?
            .compactMap(UUID.init(uuidString:)) ?? []
        if let data = userDefaults.data(forKey: StorageKeys.codexCustomAccounts),
           let decoded = try? JSONDecoder().decode([CodexAccount].self, from: data) {
            customAccounts = decoded.filter { !$0.isDefault }
        }
        pruneAccountOrder()
    }

    private func saveCustomAccounts() {
        guard let data = try? JSONEncoder().encode(customAccounts) else { return }
        userDefaults.set(data, forKey: StorageKeys.codexCustomAccounts)
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == CodexAccount.defaultName {
            userDefaults.removeObject(forKey: StorageKeys.codexDefaultAccountName)
        } else {
            userDefaults.set(defaultAccountName, forKey: StorageKeys.codexDefaultAccountName)
        }
    }

    private func saveDefaultAccountEnabled() {
        if defaultAccountIsEnabled {
            userDefaults.removeObject(forKey: StorageKeys.codexDefaultAccountEnabled)
        } else {
            userDefaults.set(false, forKey: StorageKeys.codexDefaultAccountEnabled)
        }
    }

    private func saveAccountOrder() {
        if accountOrder.isEmpty {
            userDefaults.removeObject(forKey: StorageKeys.codexAccountOrder)
        } else {
            userDefaults.set(accountOrder.map(\.uuidString), forKey: StorageKeys.codexAccountOrder)
        }
    }

    private func orderedAccounts(from unordered: [CodexAccount]) -> [CodexAccount] {
        guard !accountOrder.isEmpty else { return unordered }
        let byID = Dictionary(uniqueKeysWithValues: unordered.map { ($0.id, $0) })
        let ordered = accountOrder.compactMap { byID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + unordered.filter { !orderedIDs.contains($0.id) }
    }

    private func pruneAccountOrder() {
        guard !accountOrder.isEmpty else { return }
        let validIDs = Set([CodexAccount.defaultID] + customAccounts.map(\.id))
        let pruned = accountOrder.filter { validIDs.contains($0) }
        guard pruned != accountOrder else { return }
        accountOrder = pruned
        saveAccountOrder()
    }
}
