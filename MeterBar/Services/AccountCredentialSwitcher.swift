import Darwin
import Foundation
import os
import Security

nonisolated struct AccountCredentialSwitch: Equatable, Sendable {
    let provider: AccountFailoverProvider
    let fromAccountID: UUID
    let toAccountID: UUID
}

nonisolated struct AccountCredentialSwitchEligibility: Equatable, Sendable {
    let isEligible: Bool
    let reason: String?

    static let eligible = Self(isEligible: true, reason: nil)

    static func ineligible(_ reason: String) -> Self {
        Self(isEligible: false, reason: reason)
    }
}

/// The sole mutation seam for provider-owned credential stores. Coordinator
/// tests inject a recorder, so unit tests never read or write the real Keychain.
protocol AccountCredentialSwitching {
    func eligibility(for provider: AccountFailoverProvider) -> AccountCredentialSwitchEligibility
    func recoverPendingTransactions() async throws
    func switchCredentials(
        provider: AccountFailoverProvider,
        from: UUID,
        to: UUID
    ) async throws
}

extension AccountCredentialSwitching {
    func eligibility(for _: AccountFailoverProvider) -> AccountCredentialSwitchEligibility { .eligible }
    func recoverPendingTransactions() async throws {}
}

nonisolated enum CredentialExchangeError: Error, Equatable {
    case sameLocation
    case missingSourceCredential
    case missingTargetCredential
    case unsupportedCredentialLayout
    case crossVolume
    case nonRegularFile
    case journalWriteFailed
    case atomicExchangeFailed(Int32)
    case postconditionFailed
    case recoveryRequired
}

nonisolated struct CredentialFileIdentity: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated struct CredentialFileExchangeRequest: Equatable, Sendable {
    let provider: AccountFailoverProvider
    let sourceAccountID: UUID
    let targetAccountID: UUID
    let sourcePath: String
    let targetPath: String
    let sourceCredentialLocation: String?
    let targetCredentialLocation: String?
}

nonisolated struct CredentialFileExchangeRecord: Codable, Equatable, Sendable {
    let provider: AccountFailoverProvider
    let sourceAccountID: UUID
    let targetAccountID: UUID
    let sourcePath: String
    let targetPath: String
    let sourceCredentialLocation: String?
    let targetCredentialLocation: String?
    let sourceIdentity: CredentialFileIdentity
    let targetIdentity: CredentialFileIdentity
}

nonisolated enum CredentialFileExchangeState: Equatable, Sendable {
    case original
    case swapped
    case inconsistent
}

nonisolated protocol CredentialFileOperating {
    func identity(at path: String) throws -> CredentialFileIdentity
    func atomicallyExchange(_ sourcePath: String, _ targetPath: String) throws
}

nonisolated protocol CredentialExchangeJournaling {
    func load() throws -> CredentialFileExchangeRecord?
    func save(_ record: CredentialFileExchangeRecord) throws
    func clear() throws
}

/// Uses Darwin's same-volume `RENAME_SWAP`. The syscall is the only credential
/// mutation: it exchanges directory entries atomically and never reads or copies
/// credential bytes into MeterBar storage.
nonisolated struct DarwinCredentialFileOperator: CredentialFileOperating {
    func identity(at path: String) throws -> CredentialFileIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw errno == ENOENT
                ? CredentialExchangeError.missingSourceCredential
                : CredentialExchangeError.atomicExchangeFailed(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CredentialExchangeError.nonRegularFile
        }
        guard info.st_size > 0 else {
            throw CredentialExchangeError.missingSourceCredential
        }
        return CredentialFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    func atomicallyExchange(_ sourcePath: String, _ targetPath: String) throws {
        guard renamex_np(sourcePath, targetPath, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            if code == EXDEV { throw CredentialExchangeError.crossVolume }
            throw CredentialExchangeError.atomicExchangeFailed(code)
        }
    }
}

/// Secret-free crash journal. Account ids, provider, file paths, and inode
/// identities are configuration metadata; credential bytes are never encoded.
nonisolated final class UserDefaultsCredentialExchangeJournal: CredentialExchangeJournaling {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() throws -> CredentialFileExchangeRecord? {
        guard let data = userDefaults.data(forKey: StorageKeys.accountCredentialExchangeJournal) else { return nil }
        return try JSONDecoder().decode(CredentialFileExchangeRecord.self, from: data)
    }

    func save(_ record: CredentialFileExchangeRecord) throws {
        let data = try JSONEncoder().encode(record)
        userDefaults.set(data, forKey: StorageKeys.accountCredentialExchangeJournal)
        guard userDefaults.synchronize(), try load() == record else {
            throw CredentialExchangeError.journalWriteFailed
        }
    }

    func clear() throws {
        userDefaults.removeObject(forKey: StorageKeys.accountCredentialExchangeJournal)
        guard userDefaults.synchronize(), try load() == nil else {
            throw CredentialExchangeError.journalWriteFailed
        }
    }
}

/// A two-state transaction: before or after one atomic filesystem exchange.
/// The persisted inode identities let startup recovery distinguish those states
/// even if the process dies immediately after the syscall.
nonisolated enum CredentialFileExchangeTransaction {
    static func prepareAndExchange(
        _ request: CredentialFileExchangeRequest,
        fileOperator: CredentialFileOperating,
        journal: CredentialExchangeJournaling
    ) throws -> CredentialFileExchangeRecord {
        guard request.sourcePath != request.targetPath else { throw CredentialExchangeError.sameLocation }
        let sourceIdentity = try fileOperator.identity(at: request.sourcePath)
        let targetIdentity: CredentialFileIdentity
        do {
            targetIdentity = try fileOperator.identity(at: request.targetPath)
        } catch CredentialExchangeError.missingSourceCredential {
            throw CredentialExchangeError.missingTargetCredential
        }
        guard sourceIdentity.device == targetIdentity.device else {
            throw CredentialExchangeError.crossVolume
        }
        let record = CredentialFileExchangeRecord(
            provider: request.provider,
            sourceAccountID: request.sourceAccountID,
            targetAccountID: request.targetAccountID,
            sourcePath: request.sourcePath,
            targetPath: request.targetPath,
            sourceCredentialLocation: request.sourceCredentialLocation,
            targetCredentialLocation: request.targetCredentialLocation,
            sourceIdentity: sourceIdentity,
            targetIdentity: targetIdentity
        )
        try journal.save(record)
        try fileOperator.atomicallyExchange(request.sourcePath, request.targetPath)
        guard try state(of: record, fileOperator: fileOperator) == .swapped else {
            throw CredentialExchangeError.postconditionFailed
        }
        return record
    }

    static func state(
        of record: CredentialFileExchangeRecord,
        fileOperator: CredentialFileOperating
    ) throws -> CredentialFileExchangeState {
        let source = try fileOperator.identity(at: record.sourcePath)
        let target = try fileOperator.identity(at: record.targetPath)
        if source == record.sourceIdentity, target == record.targetIdentity { return .original }
        if source == record.targetIdentity, target == record.sourceIdentity { return .swapped }
        return .inconsistent
    }
}

@MainActor
final class LiveAccountCredentialSwitcher: AccountCredentialSwitching {
    static let shared = LiveAccountCredentialSwitcher()

    private let claudeAccounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore
    private let failoverSettings: AccountFailoverSettingsStore
    private let fileOperator: CredentialFileOperating
    private let journal: CredentialExchangeJournaling
    private let keychainItemProbe: (String) -> Bool

    init(
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        failoverSettings: AccountFailoverSettingsStore? = nil,
        fileOperator: CredentialFileOperating = DarwinCredentialFileOperator(),
        journal: CredentialExchangeJournaling? = nil,
        keychainItemProbe: ((String) -> Bool)? = nil
    ) {
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.failoverSettings = failoverSettings ?? .shared
        self.fileOperator = fileOperator
        self.journal = journal ?? UserDefaultsCredentialExchangeJournal()
        self.keychainItemProbe = keychainItemProbe ?? Self.keychainItemMayExist(service:)
    }

    func eligibility(for provider: AccountFailoverProvider) -> AccountCredentialSwitchEligibility {
        do {
            let paths = try credentialPaths(for: provider)
            guard paths.count >= 2 else {
                return .ineligible("Add and sign in to at least two accounts.")
            }
            let identities = try paths.map(fileOperator.identity(at:))
            guard Set(identities.map(\.device)).count == 1 else {
                return .ineligible("Credential files must be on the same volume for an atomic switch.")
            }
            return .eligible
        } catch CredentialExchangeError.unsupportedCredentialLayout {
            return .ineligible(
                "Claude Keychain and mixed Keychain/file layouts are not switched automatically because "
                    + "Security.framework has no atomic multi-item transaction. Use file-backed profiles."
            )
        } catch {
            return .ineligible("Every enabled account must have a readable provider credential file.")
        }
    }

    func recoverPendingTransactions() async throws {
        guard let record = try journal.load() else { return }
        switch try CredentialFileExchangeTransaction.state(of: record, fileOperator: fileOperator) {
        case .original:
            try journal.clear()
        case .swapped:
            guard reconcileAccountLocations(for: record) else {
                throw CredentialExchangeError.recoveryRequired
            }
            failoverSettings.setActiveAccountID(record.targetAccountID, for: record.provider)
            try journal.clear()
        case .inconsistent:
            throw CredentialExchangeError.recoveryRequired
        }
    }

    func switchCredentials(
        provider: AccountFailoverProvider,
        from sourceID: UUID,
        to targetID: UUID
    ) async throws {
        try await recoverPendingTransactions()
        let locations = try credentialLocations(provider: provider, sourceID: sourceID, targetID: targetID)
        let record = try CredentialFileExchangeTransaction.prepareAndExchange(
            CredentialFileExchangeRequest(
                provider: provider,
                sourceAccountID: sourceID,
                targetAccountID: targetID,
                sourcePath: locations.sourcePath,
                targetPath: locations.targetPath,
                sourceCredentialLocation: locations.sourceLocation,
                targetCredentialLocation: locations.targetLocation
            ),
            fileOperator: fileOperator,
            journal: journal
        )
        guard reconcileAccountLocations(for: record) else {
            throw CredentialExchangeError.recoveryRequired
        }
        failoverSettings.setActiveAccountID(targetID, for: provider)
        do {
            try journal.clear()
        } catch {
            // The credential exchange and logical mapping are already committed.
            // Retaining the secret-free journal is safe and lets a later startup
            // retry the idempotent cleanup without misreporting this switch.
            AppLog.storage.error("Automatic account switch recovery journal cleanup will be retried.")
        }
    }

    private func credentialPaths(for provider: AccountFailoverProvider) throws -> [String] {
        switch provider {
        case .claudeCode:
            return try claudeAccounts.enabledAccounts.map(claudeFileCredentialPath(for:))
        case .codexCli:
            return codexAccounts.enabledAccounts.map(CodexHomeDirectory.authFilePath(for:))
        }
    }

    private func credentialLocations(
        provider: AccountFailoverProvider,
        sourceID: UUID,
        targetID: UUID
    ) throws -> (sourcePath: String, targetPath: String, sourceLocation: String?, targetLocation: String?) {
        switch provider {
        case .claudeCode:
            guard let source = claudeAccounts.enabledAccounts.first(where: { $0.id == sourceID }),
                  let target = claudeAccounts.enabledAccounts.first(where: { $0.id == targetID }) else {
                throw CredentialExchangeError.missingSourceCredential
            }
            return (
                try claudeFileCredentialPath(for: source),
                try claudeFileCredentialPath(for: target),
                source.configDirectory,
                target.configDirectory
            )
        case .codexCli:
            guard let source = codexAccounts.enabledAccounts.first(where: { $0.id == sourceID }),
                  let target = codexAccounts.enabledAccounts.first(where: { $0.id == targetID }) else {
                throw CredentialExchangeError.missingSourceCredential
            }
            return (
                CodexHomeDirectory.authFilePath(for: source),
                CodexHomeDirectory.authFilePath(for: target),
                source.homeDirectory,
                target.homeDirectory
            )
        }
    }

    private func claudeFileCredentialPath(for account: ClaudeCodeAccount) throws -> String {
        for candidate in ClaudeCredentialResolver.candidates(for: account) {
            switch candidate {
            case let .keychain(service):
                if keychainItemProbe(service) {
                    throw CredentialExchangeError.unsupportedCredentialLayout
                }
            case let .file(path):
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        throw CredentialExchangeError.missingSourceCredential
    }

    private static func keychainItemMayExist(service: String) -> Bool {
        let query = ClaudeKeychainQuery.applyingAccessMode(
            .background,
            to: [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
        )
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status != errSecItemNotFound
    }

    private func reconcileAccountLocations(for record: CredentialFileExchangeRecord) -> Bool {
        switch record.provider {
        case .claudeCode:
            let source = claudeAccounts.accounts.first(where: { $0.id == record.sourceAccountID })
            let target = claudeAccounts.accounts.first(where: { $0.id == record.targetAccountID })
            if source?.configDirectory == record.targetCredentialLocation,
               target?.configDirectory == record.sourceCredentialLocation { return true }
            return claudeAccounts.exchangeCredentialLocations(
                from: record.sourceAccountID,
                to: record.targetAccountID,
                expectedSource: record.sourceCredentialLocation,
                expectedTarget: record.targetCredentialLocation
            )
        case .codexCli:
            let source = codexAccounts.accounts.first(where: { $0.id == record.sourceAccountID })
            let target = codexAccounts.accounts.first(where: { $0.id == record.targetAccountID })
            if source?.homeDirectory == record.targetCredentialLocation,
               target?.homeDirectory == record.sourceCredentialLocation { return true }
            return codexAccounts.exchangeCredentialLocations(
                from: record.sourceAccountID,
                to: record.targetAccountID,
                expectedSource: record.sourceCredentialLocation,
                expectedTarget: record.targetCredentialLocation
            )
        }
    }
}
