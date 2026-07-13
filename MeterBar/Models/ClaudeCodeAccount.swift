import Combine
import Foundation

// MARK: - ClaudeCodeAccount

nonisolated struct ClaudeCodeAccount: Codable, Equatable, Identifiable, Sendable {
    static let defaultName = "Default CLI Profile"

    /// Fixed sentinel id for the default CLI profile. Built from raw bytes
    /// (00000000-0000-0000-0000-000000000001) so it stays deterministic without a
    /// force-unwrap of `UUID(uuidString:)`.
    static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    static let defaultAccount = ClaudeCodeAccount(
        id: Self.defaultID,
        name: Self.defaultName,
        configDirectory: nil
    )

    let id: UUID
    var name: String
    var configDirectory: String?

    var isDefault: Bool {
        id == Self.defaultID
    }

    /// Resolves the default Claude CLI profile directory for user-facing paths
    /// and Finder actions without mutating the process environment in tests.
    static func defaultConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        guard let rawValue = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return (realHomeDirectory as NSString).appendingPathComponent(".claude")
        }

        if rawValue == "~" {
            return realHomeDirectory
        }
        if rawValue.hasPrefix("~/") {
            return (realHomeDirectory as NSString).appendingPathComponent(String(rawValue.dropFirst(2)))
        }
        return (rawValue as NSString).standardizingPath
    }
}

// MARK: - ClaudeCodeAccountStore

final class ClaudeCodeAccountStore: ObservableObject {
    static let shared = ClaudeCodeAccountStore()

    @Published private(set) var customAccounts: [ClaudeCodeAccount] = []
    @Published private(set) var defaultAccountName = ClaudeCodeAccount.defaultName
    @Published private(set) var accountOrder: [UUID] = []

    private let userDefaults: UserDefaults
    private let storageKey = StorageKeys.claudeCodeCustomAccounts
    private let defaultNameStorageKey = StorageKeys.claudeCodeDefaultAccountName
    private let accountOrderStorageKey = StorageKeys.claudeCodeAccountOrder

    var accounts: [ClaudeCodeAccount] {
        orderedAccounts(from: [
            ClaudeCodeAccount(
                id: ClaudeCodeAccount.defaultID,
                name: defaultAccountName,
                configDirectory: nil
            )
        ] + customAccounts)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func addAccount(name: String, configDirectory: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty else { return }

        let account = ClaudeCodeAccount(
            id: UUID(),
            name: trimmedName,
            configDirectory: (trimmedDirectory as NSString).standardizingPath
        )
        customAccounts.append(account)
        if !accountOrder.isEmpty {
            accountOrder.append(account.id)
            saveAccountOrder()
        }
        saveCustomAccounts()
    }

    func updateAccount(id: UUID, name: String, configDirectory: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if id == ClaudeCodeAccount.defaultID {
            guard trimmedName != defaultAccountName else { return }
            defaultAccountName = trimmedName
            saveDefaultAccountName()
            return
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else { return }

        var updatedAccount = customAccounts[index]
        updatedAccount.name = trimmedName

        if let configDirectory {
            let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectory.isEmpty else { return }
            updatedAccount.configDirectory = (trimmedDirectory as NSString).standardizingPath
        }

        guard updatedAccount != customAccounts[index] else { return }
        var updatedAccounts = customAccounts
        updatedAccounts[index] = updatedAccount
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func removeAccount(id: UUID) {
        guard id != ClaudeCodeAccount.defaultID else { return }
        customAccounts.removeAll { $0.id == id }
        accountOrder.removeAll { $0 == id }
        saveAccountOrder()
        saveCustomAccounts()
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = accounts
        guard !ordered.isEmpty else { return }

        let movingIndexes = source.sorted()
        guard movingIndexes.allSatisfy({ ordered.indices.contains($0) }) else { return }

        let movingAccounts = movingIndexes.map { ordered[$0] }
        for index in movingIndexes.reversed() {
            ordered.remove(at: index)
        }

        let removedBeforeDestination = movingIndexes.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removedBeforeDestination, ordered.count))
        ordered.insert(contentsOf: movingAccounts, at: adjustedDestination)

        accountOrder = ordered.map(\.id)
        saveAccountOrder()
    }

    private func load() {
        let storedDefaultName = userDefaults.string(forKey: defaultNameStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedDefaultName, !storedDefaultName.isEmpty {
            defaultAccountName = storedDefaultName
        }

        accountOrder = userDefaults.stringArray(forKey: accountOrderStorageKey)?
            .compactMap(UUID.init(uuidString:)) ?? []

        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ClaudeCodeAccount].self, from: data) else {
            return
        }

        customAccounts = decoded.filter { !$0.isDefault }
        pruneAccountOrder()
    }

    private func saveCustomAccounts() {
        guard let data = try? JSONEncoder().encode(customAccounts) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == ClaudeCodeAccount.defaultName {
            userDefaults.removeObject(forKey: defaultNameStorageKey)
        } else {
            userDefaults.set(defaultAccountName, forKey: defaultNameStorageKey)
        }
    }

    private func saveAccountOrder() {
        if accountOrder.isEmpty {
            userDefaults.removeObject(forKey: accountOrderStorageKey)
        } else {
            userDefaults.set(accountOrder.map(\.uuidString), forKey: accountOrderStorageKey)
        }
    }

    private func orderedAccounts(from unorderedAccounts: [ClaudeCodeAccount]) -> [ClaudeCodeAccount] {
        guard !accountOrder.isEmpty else { return unorderedAccounts }

        let accountsByID = Dictionary(uniqueKeysWithValues: unorderedAccounts.map { ($0.id, $0) })
        let ordered = accountOrder.compactMap { accountsByID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        let unordered = unorderedAccounts.filter { !orderedIDs.contains($0.id) }
        return ordered + unordered
    }

    private func pruneAccountOrder() {
        guard !accountOrder.isEmpty else { return }

        let validIDs = Set([ClaudeCodeAccount.defaultID] + customAccounts.map(\.id))
        let prunedOrder = accountOrder.filter { validIDs.contains($0) }
        if prunedOrder != accountOrder {
            accountOrder = prunedOrder
            saveAccountOrder()
        }
    }
}
