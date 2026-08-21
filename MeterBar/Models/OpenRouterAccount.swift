import Combine
import Foundation
import MeterBarShared

/// One OpenRouter API key under management.
///
/// The key material itself never lives here — it is a Keychain item keyed by
/// `id` (see `OpenRouterService.keychainKey(for:)`). Only non-secret metadata
/// (display name, enablement, order) persists to UserDefaults, and only that
/// metadata mirrors to the CLI's refresh-configuration file.
nonisolated struct OpenRouterAccount: Codable, Equatable, Identifiable, Sendable {
    static let defaultName = "Default Key"
    static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4))

    static let defaultAccount = OpenRouterAccount(
        id: Self.defaultID,
        name: Self.defaultName
    )

    let id: UUID
    var name: String
    var isEnabled: Bool

    init(id: UUID, name: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Backward-compat: keys persisted before the enable/disable flag
        // existed decode as enabled.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var isDefault: Bool { id == Self.defaultID }
}

nonisolated enum OpenRouterAccountMutationOutcome: Equatable, Sendable {
    case updated
    case unchanged
    case rejectedLastEnabledAccount
}

final class OpenRouterAccountStore: ObservableObject {
    /// In demo mode the store is projected from the default account only, so
    /// provider cards title generically ("OpenRouter") and never surface real
    /// key names. The `init(accounts:)` projection reads and writes no real
    /// `.standard` data.
    static let shared = DemoMode.isActive
        ? OpenRouterAccountStore(accounts: [.defaultAccount])
        : OpenRouterAccountStore()

    @Published private(set) var customAccounts: [OpenRouterAccount] = []
    @Published private(set) var defaultAccountName = OpenRouterAccount.defaultName
    @Published private(set) var defaultAccountIsEnabled = true
    @Published private(set) var accountOrder: [UUID] = []

    private let userDefaults: UserDefaults
    private let refreshConfigurationDirectory: URL?

    var accounts: [OpenRouterAccount] {
        orderedAccounts(from: [
            OpenRouterAccount(
                id: OpenRouterAccount.defaultID,
                name: defaultAccountName,
                isEnabled: defaultAccountIsEnabled
            )
        ] + customAccounts)
    }

    var enabledAccounts: [OpenRouterAccount] {
        accounts.filter(\.isEnabled)
    }

    init(userDefaults: UserDefaults = .standard, refreshConfigurationDirectory: URL? = nil) {
        self.userDefaults = userDefaults
        self.refreshConfigurationDirectory = refreshConfigurationDirectory
            ?? (userDefaults === UserDefaults.standard ? SharedMetricsStore.containerURL : nil)
        load()
        persistRefreshConfiguration()
    }

    /// Read-only projection used by the bundled CLI.
    init(accounts: [OpenRouterAccount]) {
        userDefaults = .standard
        refreshConfigurationDirectory = nil
        let defaultAccount = accounts.first(where: \.isDefault) ?? .defaultAccount
        defaultAccountName = defaultAccount.name
        defaultAccountIsEnabled = defaultAccount.isEnabled
        customAccounts = accounts.filter { !$0.isDefault }
        accountOrder = accounts.map(\.id)
    }

    /// Returns the created account so the caller can store its key material in
    /// the Keychain under the returned id — the store deliberately owns no
    /// secrets.
    @discardableResult
    func addAccount(name: String) -> OpenRouterAccount? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let account = OpenRouterAccount(id: UUID(), name: trimmedName)
        customAccounts.append(account)
        if !accountOrder.isEmpty {
            accountOrder.append(account.id)
            saveAccountOrder()
        }
        saveCustomAccounts()
        return account
    }

    func updateAccount(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if id == OpenRouterAccount.defaultID {
            guard trimmedName != defaultAccountName else { return }
            defaultAccountName = trimmedName
            saveDefaultAccountName()
            return
        }

        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else { return }
        guard customAccounts[index].name != trimmedName else { return }
        var updatedAccounts = customAccounts
        updatedAccounts[index].name = trimmedName
        customAccounts = updatedAccounts
        saveCustomAccounts()
    }

    func canDisableAccount(id: UUID) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        return !account.isEnabled || enabledAccounts.count > 1
    }

    func canRemoveAccount(id: UUID) -> Bool {
        guard id != OpenRouterAccount.defaultID,
              let account = customAccounts.first(where: { $0.id == id }) else {
            return false
        }
        return !account.isEnabled || enabledAccounts.count > 1
    }

    @discardableResult
    func removeAccount(id: UUID) -> OpenRouterAccountMutationOutcome {
        guard id != OpenRouterAccount.defaultID,
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
    func setEnabled(_ enabled: Bool, for id: UUID) -> OpenRouterAccountMutationOutcome {
        if id == OpenRouterAccount.defaultID {
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

    private func load() {
        if let name = userDefaults.string(forKey: StorageKeys.openRouterDefaultAccountName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            defaultAccountName = name
        }
        if userDefaults.object(forKey: StorageKeys.openRouterDefaultAccountEnabled) != nil {
            defaultAccountIsEnabled = userDefaults.bool(forKey: StorageKeys.openRouterDefaultAccountEnabled)
        }
        accountOrder = userDefaults.stringArray(forKey: StorageKeys.openRouterAccountOrder)?
            .compactMap(UUID.init(uuidString:)) ?? []
        if let data = userDefaults.data(forKey: StorageKeys.openRouterCustomAccounts),
           let decoded = try? JSONDecoder().decode([OpenRouterAccount].self, from: data) {
            customAccounts = decoded.filter { !$0.isDefault }
        }
        restoreDefaultAccountIfNeeded()
        pruneAccountOrder()
    }

    private func saveCustomAccounts() {
        guard let data = try? JSONEncoder().encode(customAccounts) else { return }
        userDefaults.set(data, forKey: StorageKeys.openRouterCustomAccounts)
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountName() {
        if defaultAccountName == OpenRouterAccount.defaultName {
            userDefaults.removeObject(forKey: StorageKeys.openRouterDefaultAccountName)
        } else {
            userDefaults.set(defaultAccountName, forKey: StorageKeys.openRouterDefaultAccountName)
        }
        persistRefreshConfiguration()
    }

    private func saveDefaultAccountEnabled() {
        if defaultAccountIsEnabled {
            userDefaults.removeObject(forKey: StorageKeys.openRouterDefaultAccountEnabled)
        } else {
            userDefaults.set(false, forKey: StorageKeys.openRouterDefaultAccountEnabled)
        }
        persistRefreshConfiguration()
    }

    private func saveAccountOrder() {
        if accountOrder.isEmpty {
            userDefaults.removeObject(forKey: StorageKeys.openRouterAccountOrder)
        } else {
            userDefaults.set(accountOrder.map(\.uuidString), forKey: StorageKeys.openRouterAccountOrder)
        }
        persistRefreshConfiguration()
    }

    private func persistRefreshConfiguration() {
        guard let refreshConfigurationDirectory else { return }
        UsageRefreshConfigurationStore.saveOpenRouterAccounts(
            accounts,
            directory: refreshConfigurationDirectory
        )
    }

    private func orderedAccounts(from unordered: [OpenRouterAccount]) -> [OpenRouterAccount] {
        guard !accountOrder.isEmpty else { return unordered }
        let byID = Dictionary(uniqueKeysWithValues: unordered.map { ($0.id, $0) })
        let ordered = accountOrder.compactMap { byID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + unordered.filter { !orderedIDs.contains($0.id) }
    }

    private func pruneAccountOrder() {
        guard !accountOrder.isEmpty else { return }
        let validIDs = Set([OpenRouterAccount.defaultID] + customAccounts.map(\.id))
        let pruned = accountOrder.filter { validIDs.contains($0) }
        guard pruned != accountOrder else { return }
        accountOrder = pruned
        saveAccountOrder()
    }

    /// Keys persisted by older builds could leave every key disabled. Keep the
    /// sentinel internally and restore only that zero-config key so refresh,
    /// widgets, and automation never wake up with an ambiguous empty set.
    private func restoreDefaultAccountIfNeeded() {
        guard !defaultAccountIsEnabled, !customAccounts.contains(where: \.isEnabled) else { return }
        defaultAccountIsEnabled = true
        saveDefaultAccountEnabled()
    }
}
