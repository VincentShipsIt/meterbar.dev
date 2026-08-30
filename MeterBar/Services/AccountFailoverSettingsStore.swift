import Combine
import Foundation

final class AccountFailoverSettingsStore: ObservableObject {
    static let shared = AccountFailoverSettingsStore()

    @Published private(set) var enabledProviders: Set<AccountFailoverProvider> = []
    @Published private(set) var activeAccountIDs: [AccountFailoverProvider: UUID] = [:]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func isEnabled(for provider: AccountFailoverProvider) -> Bool {
        enabledProviders.contains(provider)
    }

    func setEnabled(_ enabled: Bool, for provider: AccountFailoverProvider) {
        var updated = enabledProviders
        if enabled {
            updated.insert(provider)
        } else {
            updated.remove(provider)
        }
        guard updated != enabledProviders else { return }
        enabledProviders = updated
        persistEnabledProviders()
    }

    func activeAccountID(
        for provider: AccountFailoverProvider,
        orderedAccountIDs: [UUID]
    ) -> UUID? {
        if let stored = activeAccountIDs[provider], orderedAccountIDs.contains(stored) {
            return stored
        }
        return nil
    }

    func setActiveAccountID(_ accountID: UUID?, for provider: AccountFailoverProvider) {
        var updated = activeAccountIDs
        updated[provider] = accountID
        guard updated != activeAccountIDs else { return }
        activeAccountIDs = updated
        persistActiveAccountIDs()
    }

    func reconcileAccounts(_ orderedAccountIDs: [UUID], for provider: AccountFailoverProvider) {
        guard let stored = activeAccountIDs[provider], !orderedAccountIDs.contains(stored) else { return }
        setActiveAccountID(nil, for: provider)
    }

    private func load() {
        let rawProviders = userDefaults.stringArray(forKey: StorageKeys.accountFailoverEnabledProviders) ?? []
        enabledProviders = Set(rawProviders.compactMap(AccountFailoverProvider.init(rawValue:)))

        guard let data = userDefaults.data(forKey: StorageKeys.accountFailoverActiveAccounts),
              let decoded = try? JSONDecoder().decode([AccountFailoverProvider: UUID].self, from: data) else {
            return
        }
        activeAccountIDs = decoded
    }

    private func persistEnabledProviders() {
        let values = enabledProviders.map(\.rawValue).sorted()
        if values.isEmpty {
            userDefaults.removeObject(forKey: StorageKeys.accountFailoverEnabledProviders)
        } else {
            userDefaults.set(values, forKey: StorageKeys.accountFailoverEnabledProviders)
        }
    }

    private func persistActiveAccountIDs() {
        guard !activeAccountIDs.isEmpty else {
            userDefaults.removeObject(forKey: StorageKeys.accountFailoverActiveAccounts)
            return
        }
        if let data = try? JSONEncoder().encode(activeAccountIDs) {
            userDefaults.set(data, forKey: StorageKeys.accountFailoverActiveAccounts)
        }
    }
}
