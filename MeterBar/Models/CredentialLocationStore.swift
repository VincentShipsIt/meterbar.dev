import Foundation

/// An account whose credential payload lives at a store-specific on-disk
/// location — `configDirectory` for Claude Code, `homeDirectory` for Codex.
/// `nil` means the CLI's own live default location.
nonisolated protocol CredentialLocationAccount: Codable {
    var id: UUID { get }
    var isDefault: Bool { get }
    var credentialLocation: String? { get set }
}

/// Shared credential-location bookkeeping for the provider account stores.
///
/// The exchange, its persistence barrier, and the verification reads used to be
/// duplicated verbatim in `ClaudeCodeAccountStore` and `CodexAccountStore`, so a
/// fix in one left the other provider's failover silently behind. Each store now
/// supplies only what genuinely differs: its account type, its storage keys, and
/// how it writes them.
protocol CredentialLocationStoring: AnyObject {
    associatedtype Account: CredentialLocationAccount

    /// Sentinel id of the profile whose location lives outside the custom list.
    static var defaultAccountID: UUID { get }

    var userDefaults: UserDefaults { get }
    /// Forces the pending write out before the post-exchange verification reads.
    var credentialPersistenceBarrier: (UserDefaults) -> Bool { get }

    var accounts: [Account] { get }
    var customAccounts: [Account] { get }
    var defaultAccountCredentialLocation: String? { get set }

    var defaultCredentialLocationStorageKey: String { get }
    var customAccountsStorageKey: String { get }

    func replaceCustomAccounts(_ accounts: [Account])
    /// Flushes both the default location and the custom-account list.
    func saveCredentialLocations()
}

extension CredentialLocationStoring {
    /// Keeps logical account identity attached to its credential after the
    /// provider-native stores exchange payloads. `nil` means the CLI's live
    /// default location, and is valid for either logical profile after a swap.
    @discardableResult
    func exchangeCredentialLocations(
        from sourceID: UUID,
        to targetID: UUID,
        expectedSource: String?,
        expectedTarget: String?
    ) -> Bool {
        guard sourceID != targetID,
              let source = accounts.first(where: { $0.id == sourceID }),
              let target = accounts.first(where: { $0.id == targetID }),
              source.credentialLocation == expectedSource
                || source.credentialLocation == expectedTarget,
              target.credentialLocation == expectedTarget
                || target.credentialLocation == expectedSource else {
            return false
        }
        setCredentialLocation(expectedTarget, for: sourceID)
        setCredentialLocation(expectedSource, for: targetID)
        saveCredentialLocations()
        guard credentialPersistenceBarrier(userDefaults) else { return false }
        return persistedCredentialLocationMatches(expectedTarget, for: sourceID)
            && persistedCredentialLocationMatches(expectedSource, for: targetID)
    }

    func setCredentialLocation(_ location: String?, for id: UUID) {
        if id == Self.defaultAccountID {
            defaultAccountCredentialLocation = location
            return
        }
        guard let index = customAccounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = customAccounts
        updated[index].credentialLocation = location
        replaceCustomAccounts(updated)
    }

    func persistedCredentialLocationMatches(_ expected: String?, for id: UUID) -> Bool {
        if id == Self.defaultAccountID {
            return userDefaults.string(forKey: defaultCredentialLocationStorageKey) == expected
        }
        guard let account = persistedCustomAccounts().first(where: { $0.id == id }) else {
            return false
        }
        return account.credentialLocation == expected
    }

    func credentialLocationsMatchPersistedState() -> Bool {
        _ = userDefaults.synchronize()
        guard userDefaults.string(forKey: defaultCredentialLocationStorageKey)
            == defaultAccountCredentialLocation else {
            return false
        }
        let persisted = persistedCustomAccounts().filter { !$0.isDefault }
        let persistedIDs = persisted.map(\.id)
        let currentIDs = customAccounts.map(\.id)
        guard Set(persistedIDs).count == persistedIDs.count,
              Set(currentIDs).count == currentIDs.count,
              Set(persistedIDs) == Set(currentIDs) else {
            return false
        }
        let persistedLocations = Dictionary(
            uniqueKeysWithValues: persisted.map { ($0.id, $0.credentialLocation) }
        )
        return customAccounts.allSatisfy { persistedLocations[$0.id] == $0.credentialLocation }
    }

    private func persistedCustomAccounts() -> [Account] {
        guard let data = userDefaults.data(forKey: customAccountsStorageKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        return decoded
    }
}
