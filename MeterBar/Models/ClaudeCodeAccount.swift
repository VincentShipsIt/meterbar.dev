import Combine
import Foundation

// MARK: - ClaudeCodeAccount

struct ClaudeCodeAccount: Codable, Equatable, Identifiable, Sendable {
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

}

// MARK: - ClaudeCodeAccountStore

final class ClaudeCodeAccountStore: ObservableObject {

    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    // MARK: Internal

    static let shared = ClaudeCodeAccountStore()

    @Published private(set) var customAccounts: [ClaudeCodeAccount] = []
    @Published private(set) var defaultAccountName = ClaudeCodeAccount.defaultName

    var accounts: [ClaudeCodeAccount] {
        [
            ClaudeCodeAccount(
                id: ClaudeCodeAccount.defaultID,
                name: defaultAccountName,
                configDirectory: nil
            ),
        ] + customAccounts
    }

    func addAccount(name: String, configDirectory: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty else {
            return
        }

        let account = ClaudeCodeAccount(
            id: UUID(),
            name: trimmedName,
            configDirectory: (trimmedDirectory as NSString).standardizingPath
        )
        customAccounts.append(account)
        saveCustomAccounts()
    }

    func updateAccount(id: UUID, name: String, configDirectory: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        if id == ClaudeCodeAccount.defaultID {
            guard trimmedName != defaultAccountName else {
                return
            }
            defaultAccountName = trimmedName
            saveDefaultAccountName()
            return
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else {
            return
        }

        var updatedAccount = customAccounts[index]
        updatedAccount.name = trimmedName

        if let configDirectory {
            let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectory.isEmpty else {
                return
            }
            updatedAccount.configDirectory = (trimmedDirectory as NSString).standardizingPath
        }

        guard updatedAccount != customAccounts[index] else {
            return
        }
        var updatedAccounts = customAccounts
        updatedAccounts[index] = updatedAccount
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func removeAccount(id: UUID) {
        guard id != ClaudeCodeAccount.defaultID else {
            return
        }
        customAccounts.removeAll { $0.id == id }
        saveCustomAccounts()
    }

    // MARK: Private

    private let userDefaults: UserDefaults
    private let storageKey = "ClaudeCodeCustomAccounts"
    private let defaultNameStorageKey = "ClaudeCodeDefaultAccountName"

    private func load() {
        let storedDefaultName = userDefaults.string(forKey: defaultNameStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedDefaultName, !storedDefaultName.isEmpty {
            defaultAccountName = storedDefaultName
        }

        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ClaudeCodeAccount].self, from: data) else {
            return
        }

        customAccounts = decoded.filter { !$0.isDefault }
    }

    private func saveCustomAccounts() {
        guard let data = try? JSONEncoder().encode(customAccounts) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == ClaudeCodeAccount.defaultName {
            userDefaults.removeObject(forKey: defaultNameStorageKey)
        } else {
            userDefaults.set(defaultAccountName, forKey: defaultNameStorageKey)
        }
    }
}
