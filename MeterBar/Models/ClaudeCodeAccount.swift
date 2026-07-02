import Combine
import Foundation

struct ClaudeCodeAccount: Codable, Equatable, Identifiable, Sendable {
    // Fixed sentinel id for the default CLI profile. Built from raw bytes
    // (00000000-0000-0000-0000-000000000001) so it stays deterministic without a
    // force-unwrap of `UUID(uuidString:)`.
    static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    let id: UUID
    var name: String
    var configDirectory: String?

    var isDefault: Bool {
        id == Self.defaultID
    }

    static let defaultAccount = ClaudeCodeAccount(
        id: Self.defaultID,
        name: "Default CLI Profile",
        configDirectory: nil
    )
}

final class ClaudeCodeAccountStore: ObservableObject {
    static let shared = ClaudeCodeAccountStore()

    @Published private(set) var customAccounts: [ClaudeCodeAccount] = []

    private let userDefaults: UserDefaults
    private let storageKey = StorageKeys.claudeCodeCustomAccounts

    var accounts: [ClaudeCodeAccount] {
        [ClaudeCodeAccount.defaultAccount] + customAccounts
    }

    private init(userDefaults: UserDefaults = .standard) {
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
        save()
    }

    func removeAccount(id: UUID) {
        guard id != ClaudeCodeAccount.defaultID else { return }
        customAccounts.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ClaudeCodeAccount].self, from: data) else {
            return
        }

        customAccounts = decoded.filter { !$0.isDefault }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(customAccounts) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
