import Combine
import Foundation
import MeterBarShared

nonisolated struct CodexAccount: Codable, Equatable, Identifiable, Sendable,
    CredentialLocationAccount {
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

    /// `CredentialLocationAccount` spelling of `homeDirectory`, so the shared
    /// exchange logic works against both providers' location fields.
    var credentialLocation: String? {
        get { homeDirectory }
        set { homeDirectory = newValue }
    }
}

nonisolated enum CodexAccountMutationOutcome: Equatable, Sendable {
    case updated
    case unchanged
    case rejectedLastEnabledAccount
}

final class CodexAccountStore: ObservableObject, CredentialLocationStoring {
    /// In demo mode the store is projected from the default account only, so
    /// provider cards title generically ("Codex") and never surface the owner's
    /// real custom-account names. The `init(accounts:)` projection reads and
    /// writes no real `.standard` data.
    static let shared = DemoMode.isActive
        ? CodexAccountStore(accounts: [.defaultAccount])
        : CodexAccountStore()

    @Published private(set) var customAccounts: [CodexAccount] = []
    @Published private(set) var defaultAccountName = CodexAccount.defaultName
    @Published private(set) var defaultAccountHomeDirectory: String?
    @Published private(set) var defaultAccountIsEnabled = true
    @Published private(set) var accountOrder: [UUID] = []

    let userDefaults: UserDefaults
    private let refreshConfigurationDirectory: URL?
    let credentialPersistenceBarrier: (UserDefaults) -> Bool

    var accounts: [CodexAccount] {
        orderedAccounts(from: [
            CodexAccount(
                id: CodexAccount.defaultID,
                name: defaultAccountName,
                homeDirectory: defaultAccountHomeDirectory,
                isEnabled: defaultAccountIsEnabled
            )
        ] + customAccounts)
    }

    var enabledAccounts: [CodexAccount] {
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
    init(accounts: [CodexAccount]) {
        userDefaults = .standard
        refreshConfigurationDirectory = nil
        credentialPersistenceBarrier = { _ in false }
        let defaultAccount = accounts.first(where: \.isDefault) ?? .defaultAccount
        defaultAccountName = defaultAccount.name
        defaultAccountHomeDirectory = defaultAccount.homeDirectory
        defaultAccountIsEnabled = defaultAccount.isEnabled
        customAccounts = accounts.filter { !$0.isDefault }
        accountOrder = accounts.map(\.id)
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
            if trimmedName != defaultAccountName {
                defaultAccountName = trimmedName
                saveDefaultAccountName()
            }
            if let homeDirectory {
                let trimmedDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                let updatedDirectory = trimmedDirectory.isEmpty
                    ? nil
                    : (trimmedDirectory as NSString).standardizingPath
                if updatedDirectory != defaultAccountHomeDirectory {
                    defaultAccountHomeDirectory = updatedDirectory
                    saveDefaultAccountHomeDirectory()
                }
            }
            return
        }

        let standardizedDirectory: String?
        if let homeDirectory {
            let trimmedDirectory = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectory.isEmpty else { return }
            standardizedDirectory = (trimmedDirectory as NSString).standardizingPath
        } else {
            standardizedDirectory = nil
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else { return }

        var updated = customAccounts[index]
        updated.name = trimmedName
        if let standardizedDirectory {
            updated.homeDirectory = standardizedDirectory
        }
        guard updated != customAccounts[index] else { return }
        var updatedAccounts = customAccounts
        updatedAccounts[index] = updated
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func canDisableAccount(id: UUID) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        return !account.isEnabled || enabledAccounts.count > 1
    }

    func canRemoveAccount(id: UUID) -> Bool {
        guard id != CodexAccount.defaultID,
              let account = customAccounts.first(where: { $0.id == id }) else {
            return false
        }
        return !account.isEnabled || enabledAccounts.count > 1
    }

    @discardableResult
    func removeAccount(id: UUID) -> CodexAccountMutationOutcome {
        guard id != CodexAccount.defaultID,
              let account = customAccounts.first(where: { $0.id == id }) else {
            return .unchanged
        }
        guard !account.isEnabled || enabledAccounts.count > 1 else {
            return .rejectedLastEnabledAccount
        }
        customAccounts.removeAll { $0.id == id }
        accountOrder.removeAll { $0 == id }
        saveAccountOrder()
        saveCustomAccounts()
        return .updated
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for id: UUID) -> CodexAccountMutationOutcome {
        if id == CodexAccount.defaultID {
            guard enabled != defaultAccountIsEnabled else { return .unchanged }
            guard enabled || enabledAccounts.count > 1 else {
                return .rejectedLastEnabledAccount
            }
            defaultAccountIsEnabled = enabled
            saveDefaultAccountEnabled()
            return .updated
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }),
              customAccounts[index].isEnabled != enabled else {
            return .unchanged
        }
        guard enabled || enabledAccounts.count > 1 else {
            return .rejectedLastEnabledAccount
        }
        var updatedAccounts = customAccounts
        updatedAccounts[index].isEnabled = enabled
        customAccounts = updatedAccounts
        saveCustomAccounts()
        return .updated
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

    // MARK: - CredentialLocationStoring

    static var defaultAccountID: UUID { CodexAccount.defaultID }

    var defaultAccountCredentialLocation: String? {
        get { defaultAccountHomeDirectory }
        set { defaultAccountHomeDirectory = newValue }
    }

    var defaultCredentialLocationStorageKey: String { StorageKeys.codexDefaultHomeDirectory }

    var customAccountsStorageKey: String { StorageKeys.codexCustomAccounts }

    func replaceCustomAccounts(_ accounts: [CodexAccount]) {
        customAccounts = accounts
    }

    func saveCredentialLocations() {
        saveDefaultAccountHomeDirectory()
        saveCustomAccounts()
    }

    private func load() {
        if let name = userDefaults.string(forKey: StorageKeys.codexDefaultAccountName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            defaultAccountName = name
        }
        if let homeDirectory = userDefaults.string(forKey: StorageKeys.codexDefaultHomeDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !homeDirectory.isEmpty {
            defaultAccountHomeDirectory = (homeDirectory as NSString).standardizingPath
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
        restoreDefaultAccountIfNeeded()
        pruneAccountOrder()
    }

    private func saveCustomAccounts() {
        guard let data = try? JSONEncoder().encode(customAccounts) else { return }
        userDefaults.set(data, forKey: StorageKeys.codexCustomAccounts)
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == CodexAccount.defaultName {
            userDefaults.removeObject(forKey: StorageKeys.codexDefaultAccountName)
        } else {
            userDefaults.set(defaultAccountName, forKey: StorageKeys.codexDefaultAccountName)
        }
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountHomeDirectory() {
        if let defaultAccountHomeDirectory {
            userDefaults.set(defaultAccountHomeDirectory, forKey: StorageKeys.codexDefaultHomeDirectory)
        } else {
            userDefaults.removeObject(forKey: StorageKeys.codexDefaultHomeDirectory)
        }
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountEnabled() {
        if defaultAccountIsEnabled {
            userDefaults.removeObject(forKey: StorageKeys.codexDefaultAccountEnabled)
        } else {
            userDefaults.set(false, forKey: StorageKeys.codexDefaultAccountEnabled)
        }
        persistRefreshConfiguration()
    }

    private func saveAccountOrder() {
        if accountOrder.isEmpty {
            userDefaults.removeObject(forKey: StorageKeys.codexAccountOrder)
        } else {
            userDefaults.set(accountOrder.map(\.uuidString), forKey: StorageKeys.codexAccountOrder)
        }
        persistRefreshConfiguration()
    }

    private func persistRefreshConfiguration() {
        guard let refreshConfigurationDirectory else { return }
        UsageRefreshConfigurationStore.saveCodexAccounts(
            accounts,
            directory: refreshConfigurationDirectory
        )
    }

    private func orderedAccounts(from unordered: [CodexAccount]) -> [CodexAccount] {
        var accountsByID: [UUID: CodexAccount] = [:]
        let uniqueAccounts = unordered.filter { account in
            guard accountsByID[account.id] == nil else { return false }
            accountsByID[account.id] = account
            return true
        }
        guard !accountOrder.isEmpty else { return uniqueAccounts }

        var orderedIDs = Set<UUID>()
        let ordered = accountOrder.compactMap { id -> CodexAccount? in
            guard let account = accountsByID[id], orderedIDs.insert(id).inserted else { return nil }
            return account
        }
        return ordered + uniqueAccounts.filter { !orderedIDs.contains($0.id) }
    }

    private func pruneAccountOrder() {
        guard !accountOrder.isEmpty else { return }
        let validIDs = Set([CodexAccount.defaultID] + customAccounts.map(\.id))
        let pruned = accountOrder.filter { validIDs.contains($0) }
        guard pruned != accountOrder else { return }
        accountOrder = pruned
        saveAccountOrder()
    }

    /// Profiles persisted by older builds could leave every account disabled.
    /// Keep the sentinel internally and restore only that zero-config profile so
    /// refresh, widgets, and automation never wake up with an ambiguous empty set.
    private func restoreDefaultAccountIfNeeded() {
        guard !defaultAccountIsEnabled, !customAccounts.contains(where: \.isEnabled) else { return }
        defaultAccountIsEnabled = true
        saveDefaultAccountEnabled()
    }
}
