import Combine
import Foundation
import MeterBarShared

// MARK: - ClaudeCodeAccount

nonisolated struct ClaudeCodeAccount: Codable, Equatable, Identifiable, Sendable,
    CredentialLocationAccount {
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
    var isEnabled: Bool

    init(id: UUID, name: String, configDirectory: String?, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.configDirectory = configDirectory
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        configDirectory = try container.decodeIfPresent(String.self, forKey: .configDirectory)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var isDefault: Bool {
        id == Self.defaultID
    }

    /// `CredentialLocationAccount` spelling of `configDirectory`, so the shared
    /// exchange logic works against both providers' location fields.
    var credentialLocation: String? {
        get { configDirectory }
        set { configDirectory = newValue }
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

        return expandConfigDirectory(rawValue, realHomeDirectory: realHomeDirectory)
    }

    /// Expands a user- or environment-supplied config-directory value the way a
    /// shell would. Claude Code derives its per-profile Keychain item from the
    /// *resolved* path, so the credential resolver and the `CLAUDE_CONFIG_DIR`
    /// handed to the CLI must agree on one expansion — an unexpanded `~/...`
    /// would hash to a service name that no Claude Code profile ever wrote.
    static func expandConfigDirectory(
        _ rawValue: String,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        ServiceSupport.expandUserPath(rawValue, realHomeDirectory: realHomeDirectory)
    }
}

// MARK: - ClaudeCodeAccountStore

final class ClaudeCodeAccountStore: ObservableObject, CredentialLocationStoring {
    /// In demo mode the store is projected from the default account only, so
    /// provider cards title generically ("Claude") and never surface the owner's
    /// real custom-account names. The `init(accounts:)` projection reads and
    /// writes no real `.standard` data.
    static let shared = DemoMode.isActive
        ? ClaudeCodeAccountStore(accounts: [.defaultAccount])
        : ClaudeCodeAccountStore()

    @Published private(set) var customAccounts: [ClaudeCodeAccount] = []
    @Published private(set) var defaultAccountName = ClaudeCodeAccount.defaultName
    @Published private(set) var defaultAccountConfigDirectory: String?
    @Published private(set) var defaultAccountIsEnabled = true
    @Published private(set) var accountOrder: [UUID] = []

    let userDefaults: UserDefaults
    private let refreshConfigurationDirectory: URL?
    let credentialPersistenceBarrier: (UserDefaults) -> Bool
    private let storageKey = StorageKeys.claudeCodeCustomAccounts
    private let defaultNameStorageKey = StorageKeys.claudeCodeDefaultAccountName
    private let defaultConfigDirectoryStorageKey = StorageKeys.claudeCodeDefaultConfigDirectory
    private let defaultEnabledStorageKey = StorageKeys.claudeCodeDefaultAccountEnabled
    private let accountOrderStorageKey = StorageKeys.claudeCodeAccountOrder

    var accounts: [ClaudeCodeAccount] {
        orderedAccounts(from: [
            ClaudeCodeAccount(
                id: ClaudeCodeAccount.defaultID,
                name: defaultAccountName,
                configDirectory: defaultAccountConfigDirectory,
                isEnabled: defaultAccountIsEnabled
            )
        ] + customAccounts)
    }

    var enabledAccounts: [ClaudeCodeAccount] {
        accounts.filter(\.isEnabled)
    }

    init(
        userDefaults: UserDefaults = .standard,
        refreshConfigurationDirectory: URL? = nil,
        credentialPersistenceBarrier: ((UserDefaults) -> Bool)? = nil
    ) {
        self.userDefaults = userDefaults
        self.refreshConfigurationDirectory = refreshConfigurationDirectory
            ?? (userDefaults === UserDefaults.standard ? SharedMetricsStore.containerURL : nil)
        self.credentialPersistenceBarrier = credentialPersistenceBarrier ?? { $0.synchronize() }
        load()
        persistRefreshConfiguration()
    }

    /// Read-only projection used by the bundled CLI.
    init(accounts: [ClaudeCodeAccount]) {
        userDefaults = .standard
        refreshConfigurationDirectory = nil
        credentialPersistenceBarrier = { _ in false }
        let defaultAccount = accounts.first(where: \.isDefault) ?? .defaultAccount
        defaultAccountName = defaultAccount.name
        defaultAccountConfigDirectory = defaultAccount.configDirectory
        defaultAccountIsEnabled = defaultAccount.isEnabled
        customAccounts = accounts.filter { !$0.isDefault }
        accountOrder = accounts.map(\.id)
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
            if trimmedName != defaultAccountName {
                defaultAccountName = trimmedName
                saveDefaultAccountName()
            }
            if let configDirectory {
                let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                let updatedDirectory = trimmedDirectory.isEmpty
                    ? nil
                    : (trimmedDirectory as NSString).standardizingPath
                if updatedDirectory != defaultAccountConfigDirectory {
                    defaultAccountConfigDirectory = updatedDirectory
                    saveDefaultAccountConfigDirectory()
                }
            }
            return
        }

        let standardizedDirectory: String?
        if let configDirectory {
            let trimmedDirectory = configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectory.isEmpty else { return }
            standardizedDirectory = (trimmedDirectory as NSString).standardizingPath
        } else {
            standardizedDirectory = nil
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else { return }

        var updatedAccount = customAccounts[index]
        updatedAccount.name = trimmedName

        if let standardizedDirectory {
            updatedAccount.configDirectory = standardizedDirectory
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

    func setEnabled(_ enabled: Bool, for id: UUID) {
        if id == ClaudeCodeAccount.defaultID {
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

    // MARK: - CredentialLocationStoring

    static var defaultAccountID: UUID { ClaudeCodeAccount.defaultID }

    var defaultAccountCredentialLocation: String? {
        get { defaultAccountConfigDirectory }
        set { defaultAccountConfigDirectory = newValue }
    }

    var defaultCredentialLocationStorageKey: String { defaultConfigDirectoryStorageKey }

    var customAccountsStorageKey: String { storageKey }

    func replaceCustomAccounts(_ accounts: [ClaudeCodeAccount]) {
        customAccounts = accounts
    }

    func saveCredentialLocations() {
        saveDefaultAccountConfigDirectory()
        saveCustomAccounts()
    }

    private func load() {
        let storedDefaultName = userDefaults.string(forKey: defaultNameStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedDefaultName, !storedDefaultName.isEmpty {
            defaultAccountName = storedDefaultName
        }

        if let storedDefaultConfigDirectory = userDefaults.string(forKey: defaultConfigDirectoryStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !storedDefaultConfigDirectory.isEmpty {
            defaultAccountConfigDirectory = (storedDefaultConfigDirectory as NSString).standardizingPath
        }

        if userDefaults.object(forKey: defaultEnabledStorageKey) != nil {
            defaultAccountIsEnabled = userDefaults.bool(forKey: defaultEnabledStorageKey)
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
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == ClaudeCodeAccount.defaultName {
            userDefaults.removeObject(forKey: defaultNameStorageKey)
        } else {
            userDefaults.set(defaultAccountName, forKey: defaultNameStorageKey)
        }
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountConfigDirectory() {
        if let defaultAccountConfigDirectory {
            userDefaults.set(defaultAccountConfigDirectory, forKey: defaultConfigDirectoryStorageKey)
        } else {
            userDefaults.removeObject(forKey: defaultConfigDirectoryStorageKey)
        }
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountEnabled() {
        if defaultAccountIsEnabled {
            userDefaults.removeObject(forKey: defaultEnabledStorageKey)
        } else {
            userDefaults.set(false, forKey: defaultEnabledStorageKey)
        }
        persistRefreshConfiguration()
    }

    private func saveAccountOrder() {
        if accountOrder.isEmpty {
            userDefaults.removeObject(forKey: accountOrderStorageKey)
        } else {
            userDefaults.set(accountOrder.map(\.uuidString), forKey: accountOrderStorageKey)
        }
        persistRefreshConfiguration()
    }

    private func persistRefreshConfiguration() {
        guard let refreshConfigurationDirectory else { return }
        UsageRefreshConfigurationStore.saveClaudeAccounts(
            accounts,
            directory: refreshConfigurationDirectory
        )
    }

    private func orderedAccounts(from unorderedAccounts: [ClaudeCodeAccount]) -> [ClaudeCodeAccount] {
        var accountsByID: [UUID: ClaudeCodeAccount] = [:]
        let uniqueAccounts = unorderedAccounts.filter { account in
            guard accountsByID[account.id] == nil else { return false }
            accountsByID[account.id] = account
            return true
        }
        guard !accountOrder.isEmpty else { return uniqueAccounts }

        var orderedIDs = Set<UUID>()
        let ordered = accountOrder.compactMap { id -> ClaudeCodeAccount? in
            guard let account = accountsByID[id], orderedIDs.insert(id).inserted else { return nil }
            return account
        }
        let unordered = uniqueAccounts.filter { !orderedIDs.contains($0.id) }
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
