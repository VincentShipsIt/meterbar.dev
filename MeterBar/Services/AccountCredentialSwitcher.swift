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
    func liveAccountID(for provider: AccountFailoverProvider) throws -> UUID
    func recoverPendingTransactions() async throws -> AccountFailoverEvent?
    func switchCredentials(for event: AccountFailoverEvent) async throws
    func completeNotification(eventID: UUID) throws
}

extension AccountCredentialSwitching {
    func eligibility(for _: AccountFailoverProvider) -> AccountCredentialSwitchEligibility { .eligible }
    func liveAccountID(for _: AccountFailoverProvider) throws -> UUID {
        throw CredentialExchangeError.liveAccountUnavailable
    }
    func recoverPendingTransactions() async throws -> AccountFailoverEvent? { nil }
    func completeNotification(eventID _: UUID) throws {}
}

nonisolated enum CredentialExchangeError: Error, Equatable {
    case sameLocation
    case missingSourceCredential
    case missingTargetCredential
    case unsupportedCredentialLayout
    case crossVolume
    case nonRegularFile
    case journalWriteFailed
    case journalAlreadyPending
    case authoritativeStateMismatch
    case transactionLockContended
    case transactionLockUnavailable(Int32)
    case atomicExchangeFailed(Int32)
    case duplicateCredentialIdentity
    case liveAccountUnavailable
    case notificationEventMismatch
    case postconditionFailed
    case recoveryRequired
}

nonisolated struct CredentialFileIdentity: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated struct CredentialFileExchangeRequest: Equatable, Sendable {
    let event: AccountFailoverEvent
    let sourcePath: String
    let targetPath: String
    let sourceCredentialLocation: String?
    let targetCredentialLocation: String?
}

nonisolated enum CredentialFileExchangePhase: String, Codable, Equatable, Sendable {
    case prepared
    case committed
}

nonisolated struct CredentialFileExchangeRecord: Codable, Equatable, Sendable {
    let event: AccountFailoverEvent
    var phase: CredentialFileExchangePhase
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

nonisolated struct CredentialCompletedAccountState: Codable, Equatable, Hashable, Sendable {
    let accountID: UUID
    let credentialLocation: String?
    let credentialPath: String
    let credentialIdentity: CredentialFileIdentity
}

nonisolated struct CredentialCompletedPathOwnership: Codable, Equatable, Hashable, Sendable {
    let accountID: UUID
    let credentialLocation: String?
    let credentialPath: String

    init(account: CredentialCompletedAccountState) {
        accountID = account.accountID
        credentialLocation = account.credentialLocation
        credentialPath = account.credentialPath
    }
}

nonisolated struct CredentialCompletedProviderState: Codable, Equatable, Sendable {
    let provider: AccountFailoverProvider
    let generation: UInt64
    let accounts: [CredentialCompletedAccountState]
    let pathOwnership: [CredentialCompletedPathOwnership]

    init(
        provider: AccountFailoverProvider,
        generation: UInt64,
        accounts: [CredentialCompletedAccountState],
        pathOwnership: [CredentialCompletedPathOwnership]? = nil
    ) {
        self.provider = provider
        self.generation = generation
        self.accounts = accounts
        self.pathOwnership = Self.mergedPathOwnership(pathOwnership ?? [], with: accounts)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AccountFailoverProvider.self, forKey: .provider)
        generation = try container.decode(UInt64.self, forKey: .generation)
        accounts = try container.decode([CredentialCompletedAccountState].self, forKey: .accounts)
        let legacyBindings = try container.decodeIfPresent(
            [CredentialCompletedAccountState].self,
            forKey: .bindingHistory
        ) ?? []
        pathOwnership = Self.mergedPathOwnership(
            try container.decodeIfPresent(
                [CredentialCompletedPathOwnership].self,
                forKey: .pathOwnership
            ) ?? legacyBindings.map(CredentialCompletedPathOwnership.init(account:)),
            with: accounts
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(generation, forKey: .generation)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(pathOwnership, forKey: .pathOwnership)
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case generation
        case accounts
        case pathOwnership
        case bindingHistory
    }

    private static func mergedPathOwnership(
        _ history: [CredentialCompletedPathOwnership],
        with accounts: [CredentialCompletedAccountState]
    ) -> [CredentialCompletedPathOwnership] {
        Array(Set(history + accounts.map(CredentialCompletedPathOwnership.init(account:)))).sorted {
            if $0.accountID != $1.accountID {
                return $0.accountID.uuidString < $1.accountID.uuidString
            }
            if $0.credentialPath != $1.credentialPath {
                return $0.credentialPath < $1.credentialPath
            }
            return ($0.credentialLocation ?? "") < ($1.credentialLocation ?? "")
        }
    }
}

/// Shared, secret-free authority for the last completed provider-file mapping.
/// Unlike bundle-local UserDefaults, this file is common to release and debug
/// builds, so a stale process cannot authorize a second exchange after WAL ack.
nonisolated struct CredentialCompletedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    private(set) var providers: [CredentialCompletedProviderState]

    init(providers: [CredentialCompletedProviderState] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.providers = providers
    }

    func state(for provider: AccountFailoverProvider) -> CredentialCompletedProviderState? {
        providers.first { $0.provider == provider }
    }

    mutating func setState(_ state: CredentialCompletedProviderState) {
        providers.removeAll { $0.provider == state.provider }
        providers.append(state)
        providers.sort { $0.provider.rawValue < $1.provider.rawValue }
    }
}

nonisolated protocol CredentialCompletedStateStoring {
    func load() throws -> CredentialCompletedState?
    func save(_ state: CredentialCompletedState) throws
}

/// Cross-process ownership for the WAL, provider-file exchange, recovery, and
/// notification acknowledgement. `flock` ownership is descriptor-scoped and
/// the kernel releases it if a process exits or crashes.
nonisolated protocol CredentialExchangeProcessLocking: AnyObject {
    /// Returns `true` when this call acquired the descriptor and `false` when
    /// the same lock object already owns it.
    func acquire() throws -> Bool
    func release()
}

nonisolated final class CredentialExchangeProcessLock: CredentialExchangeProcessLocking, @unchecked Sendable {
    private let fileURL: URL
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func acquire() throws -> Bool {
        try stateLock.withLock {
            guard descriptor < 0 else { return false }
            do {
                try SecureFileWriter.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            } catch {
                throw CredentialExchangeError.transactionLockUnavailable(Int32((error as NSError).code))
            }
            let candidate = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard candidate >= 0 else {
                throw CredentialExchangeError.transactionLockUnavailable(errno)
            }
            guard fchmod(candidate, 0o600) == 0 else {
                let code = errno
                close(candidate)
                throw CredentialExchangeError.transactionLockUnavailable(code)
            }
            guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(candidate)
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw CredentialExchangeError.transactionLockContended
                }
                throw CredentialExchangeError.transactionLockUnavailable(code)
            }
            descriptor = candidate
            return true
        }
    }

    func release() {
        stateLock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("account-failover", isDirectory: true)
            .appendingPathComponent("transaction.lock")
    }

    deinit { release() }
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

/// Secret-free durable WAL and local-notification outbox. It contains only
/// provider/account metadata, file paths, inode identities, and display-safe
/// event metadata. Credential bytes never enter this app-owned file.
nonisolated final class DurableCredentialExchangeJournal: CredentialExchangeJournaling {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load() throws -> CredentialFileExchangeRecord? {
        try DurableCredentialMetadataFile.load(CredentialFileExchangeRecord.self, from: fileURL)
    }

    func save(_ record: CredentialFileExchangeRecord) throws {
        try DurableCredentialMetadataFile.save(record, to: fileURL)
        guard try load() == record else { throw CredentialExchangeError.journalWriteFailed }
    }

    func clear() throws {
        try DurableCredentialMetadataFile.clear(fileURL)
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("account-failover", isDirectory: true)
            .appendingPathComponent("transaction.json")
    }
}

nonisolated final class DurableCredentialCompletedStateStore: CredentialCompletedStateStoring {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load() throws -> CredentialCompletedState? {
        guard let state = try DurableCredentialMetadataFile.load(CredentialCompletedState.self, from: fileURL),
              state.schemaVersion == CredentialCompletedState.currentSchemaVersion else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                throw CredentialExchangeError.authoritativeStateMismatch
            }
            return nil
        }
        return state
    }

    func save(_ state: CredentialCompletedState) throws {
        try DurableCredentialMetadataFile.save(state, to: fileURL)
        guard try load() == state else { throw CredentialExchangeError.journalWriteFailed }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("account-failover", isDirectory: true)
            .appendingPathComponent("completed-state.json")
    }
}

nonisolated private enum DurableCredentialMetadataFile {
    static let maximumBytes = 64 * 1024

    static func load<Value: Decodable>(_ type: Value.Type, from fileURL: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= maximumBytes else { throw CredentialExchangeError.journalWriteFailed }
        return try JSONDecoder().decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw CredentialExchangeError.journalWriteFailed }
        try replaceDurably(data, at: destination)
    }

    static func clear(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard unlink(fileURL.path) == 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
        try syncDirectory(fileURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CredentialExchangeError.journalWriteFailed
        }
    }

    private static func replaceDurably(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try SecureFileWriter.ensurePrivateDirectory(directory)
        let staging = directory.appendingPathComponent(".credential-metadata.\(UUID().uuidString).partial")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
        var isOpen = true
        var published = false
        defer {
            if isOpen { close(descriptor) }
            if !published { try? FileManager.default.removeItem(at: staging) }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw CredentialExchangeError.atomicExchangeFailed(errno)
        }
        try writeAll(data, descriptor: descriptor)
        try fullSync(descriptor)
        guard close(descriptor) == 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
        isOpen = false
        guard rename(staging.path, destination.path) == 0 else {
            throw CredentialExchangeError.atomicExchangeFailed(errno)
        }
        published = true
        try syncDirectory(directory)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CredentialExchangeError.atomicExchangeFailed(errno)
                }
                offset += count
            }
        }
    }

    private static func fullSync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncError = errno
        if fullSyncError == EINVAL || fullSyncError == ENOTSUP {
            guard fsync(descriptor) == 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
            return
        }
        throw CredentialExchangeError.atomicExchangeFailed(fullSyncError)
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
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
        guard try journal.load() == nil else { throw CredentialExchangeError.journalAlreadyPending }
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
        guard sourceIdentity != targetIdentity else {
            throw CredentialExchangeError.duplicateCredentialIdentity
        }
        let record = CredentialFileExchangeRecord(
            event: request.event,
            phase: .prepared,
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
    private let completedStateStore: CredentialCompletedStateStoring
    private let transactionLock: CredentialExchangeProcessLocking
    private let keychainItemProbe: (String) -> Bool

    init(
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        failoverSettings: AccountFailoverSettingsStore? = nil,
        fileOperator: CredentialFileOperating = DarwinCredentialFileOperator(),
        journal: CredentialExchangeJournaling? = nil,
        completedStateStore: CredentialCompletedStateStoring? = nil,
        transactionLock: CredentialExchangeProcessLocking? = nil,
        keychainItemProbe: ((String) -> Bool)? = nil
    ) {
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.failoverSettings = failoverSettings ?? .shared
        self.fileOperator = fileOperator
        self.journal = journal ?? DurableCredentialExchangeJournal()
        self.completedStateStore = completedStateStore ?? DurableCredentialCompletedStateStore()
        self.transactionLock = transactionLock ?? CredentialExchangeProcessLock()
        self.keychainItemProbe = keychainItemProbe ?? Self.keychainItemMayExist(service:)
    }

    func eligibility(for provider: AccountFailoverProvider) -> AccountCredentialSwitchEligibility {
        do {
            let accounts = try credentialAccounts(for: provider)
            guard accounts.count >= 2 else {
                return .ineligible("Add and sign in to at least two accounts.")
            }
            _ = try liveAccountID(for: provider)
            guard Set(accounts.map(\.path)).count == accounts.count else {
                return .ineligible("Each account must use a distinct provider credential path.")
            }
            let identities = try accounts.map { try fileOperator.identity(at: $0.path) }
            guard Set(identities.map(\.device)).count == 1 else {
                return .ineligible("Credential files must be on the same volume for an atomic switch.")
            }
            guard Set(identities).count == identities.count else {
                return .ineligible("Each account must use a distinct provider credential file.")
            }
            let acquiredNow = try transactionLock.acquire()
            defer {
                if acquiredNow { transactionLock.release() }
            }
            try validateAuthoritativeState(
                for: provider,
                initializeIfMissing: false,
                reconcileAccountSetChanges: try journal.load() == nil
            )
            return .eligible
        } catch CredentialExchangeError.unsupportedCredentialLayout {
            return .ineligible(
                "Claude Keychain and mixed Keychain/file layouts are not switched automatically because "
                    + "Security.framework has no atomic multi-item transaction. Use file-backed profiles."
            )
        } catch CredentialExchangeError.liveAccountUnavailable {
            return .ineligible(
                "Exactly one enabled account must map to the provider's live default credential path."
            )
        } catch CredentialExchangeError.authoritativeStateMismatch {
            return .ineligible(
                "This MeterBar build's account mapping differs from the shared live credential state."
            )
        } catch CredentialExchangeError.transactionLockContended {
            return .ineligible("Another MeterBar instance is completing an automatic account switch.")
        } catch {
            return .ineligible("Every enabled account must have a readable provider credential file.")
        }
    }

    func liveAccountID(for provider: AccountFailoverProvider) throws -> UUID {
        let mappingIsCurrent: Bool
        switch provider {
        case .claudeCode:
            mappingIsCurrent = claudeAccounts.credentialLocationsMatchPersistedState()
        case .codexCli:
            mappingIsCurrent = codexAccounts.credentialLocationsMatchPersistedState()
        }
        guard mappingIsCurrent else { throw CredentialExchangeError.liveAccountUnavailable }
        let canonicalPath = canonicalCredentialPath(for: provider)
        let matches = try credentialAccounts(for: provider).filter { $0.path == canonicalPath }
        guard matches.count == 1, let accountID = matches.first?.id else {
            throw CredentialExchangeError.liveAccountUnavailable
        }
        return accountID
    }

    func recoverPendingTransactions() async throws -> AccountFailoverEvent? {
        _ = try transactionLock.acquire()
        var retainOwnership = false
        defer {
            if !retainOwnership { transactionLock.release() }
        }
        guard var record = try journal.load() else { return nil }
        let state = try CredentialFileExchangeTransaction.state(of: record, fileOperator: fileOperator)
        switch (record.phase, state) {
        case (.prepared, .original):
            try journal.clear()
            return nil
        case (.prepared, .swapped):
            try commitLogicalMapping(for: record)
            record.phase = .committed
            try journal.save(record)
            try advanceAuthoritativeState(for: record)
            retainOwnership = true
            return record.event
        case (.committed, .swapped):
            try commitLogicalMapping(for: record)
            try advanceAuthoritativeState(for: record)
            retainOwnership = true
            return record.event
        case (_, .inconsistent), (.committed, .original):
            throw CredentialExchangeError.recoveryRequired
        }
    }

    func switchCredentials(for event: AccountFailoverEvent) async throws {
        let acquiredNow = try transactionLock.acquire()
        var retainOwnership = false
        defer {
            if acquiredNow, !retainOwnership { transactionLock.release() }
        }
        guard try journal.load() == nil else { throw CredentialExchangeError.journalAlreadyPending }
        guard try liveAccountID(for: event.provider) == event.fromAccountID else {
            throw CredentialExchangeError.liveAccountUnavailable
        }
        try validateAuthoritativeState(
            for: event.provider,
            initializeIfMissing: true,
            reconcileAccountSetChanges: true
        )
        let locations = try credentialLocations(
            provider: event.provider,
            sourceID: event.fromAccountID,
            targetID: event.toAccountID
        )
        let record = try CredentialFileExchangeTransaction.prepareAndExchange(
            CredentialFileExchangeRequest(
                event: event,
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
        failoverSettings.setActiveAccountID(event.toAccountID, for: event.provider)
        var committed = record
        committed.phase = .committed
        try journal.save(committed)
        try advanceAuthoritativeState(for: committed)
        retainOwnership = true
    }

    func completeNotification(eventID: UUID) throws {
        let acquiredNow = try transactionLock.acquire()
        var completed = false
        defer {
            if acquiredNow, !completed { transactionLock.release() }
        }
        guard let record = try journal.load(),
              record.phase == .committed,
              record.event.id == eventID else {
            throw CredentialExchangeError.notificationEventMismatch
        }
        try advanceAuthoritativeState(for: record)
        try journal.clear()
        completed = true
        transactionLock.release()
    }

    private func credentialAccounts(for provider: AccountFailoverProvider) throws -> [(id: UUID, path: String)] {
        try credentialAccountDescriptors(for: provider).map { ($0.id, $0.path) }
    }

    private func canonicalCredentialPath(for provider: AccountFailoverProvider) -> String {
        switch provider {
        case .claudeCode:
            return Self.standardized(
                (ClaudeCodeAccount.defaultConfigDirectory() as NSString).appendingPathComponent(".credentials.json")
            )
        case .codexCli:
            return Self.standardized(CodexHomeDirectory.authFilePath())
        }
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
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
                if FileManager.default.fileExists(atPath: path) { return Self.standardized(path) }
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
        switch record.event.provider {
        case .claudeCode:
            return claudeAccounts.exchangeCredentialLocations(
                from: record.event.fromAccountID,
                to: record.event.toAccountID,
                expectedSource: record.sourceCredentialLocation,
                expectedTarget: record.targetCredentialLocation
            )
        case .codexCli:
            return codexAccounts.exchangeCredentialLocations(
                from: record.event.fromAccountID,
                to: record.event.toAccountID,
                expectedSource: record.sourceCredentialLocation,
                expectedTarget: record.targetCredentialLocation
            )
        }
    }

    private func commitLogicalMapping(for record: CredentialFileExchangeRecord) throws {
        guard reconcileAccountLocations(for: record) else {
            throw CredentialExchangeError.recoveryRequired
        }
        failoverSettings.setActiveAccountID(record.event.toAccountID, for: record.event.provider)
    }

    private func validateAuthoritativeState(
        for provider: AccountFailoverProvider,
        initializeIfMissing: Bool,
        reconcileAccountSetChanges: Bool
    ) throws {
        let currentAccounts = try completedAccountSnapshot(for: provider)
        var completedState = try completedStateStore.load() ?? CredentialCompletedState()
        guard let authoritative = completedState.state(for: provider) else {
            guard initializeIfMissing else { return }
            completedState.setState(CredentialCompletedProviderState(
                provider: provider,
                generation: 0,
                accounts: currentAccounts
            ))
            try completedStateStore.save(completedState)
            return
        }
        guard pathsRespectOwnership(currentAccounts, history: authoritative.pathOwnership) else {
            throw CredentialExchangeError.authoritativeStateMismatch
        }
        guard authoritative.accounts != currentAccounts else { return }
        guard reconcileAccountSetChanges,
              authoritative.generation < UInt64.max,
              accountSnapshotChangeIsSafe(from: authoritative.accounts, to: currentAccounts) else {
            throw CredentialExchangeError.authoritativeStateMismatch
        }
        completedState.setState(CredentialCompletedProviderState(
            provider: provider,
            generation: authoritative.generation + 1,
            accounts: currentAccounts,
            pathOwnership: authoritative.pathOwnership
        ))
        try completedStateStore.save(completedState)
    }

    private func advanceAuthoritativeState(for record: CredentialFileExchangeRecord) throws {
        let currentAccounts = try completedAccountSnapshot(for: record.event.provider)
        guard transitionMatches(record: record, before: nil, after: currentAccounts) else {
            throw CredentialExchangeError.authoritativeStateMismatch
        }
        var completedState = try completedStateStore.load() ?? CredentialCompletedState()
        guard let authoritative = completedState.state(for: record.event.provider) else {
            guard transitionMatches(record: record, before: nil, after: currentAccounts) else {
                throw CredentialExchangeError.authoritativeStateMismatch
            }
            completedState.setState(CredentialCompletedProviderState(
                provider: record.event.provider,
                generation: 1,
                accounts: currentAccounts
            ))
            try completedStateStore.save(completedState)
            return
        }
        let transactionOwnership = currentAccounts.filter {
            $0.accountID == record.event.fromAccountID || $0.accountID == record.event.toAccountID
        }
        .map(CredentialCompletedPathOwnership.init(account:))
        guard pathsRespectOwnership(
            currentAccounts,
            history: authoritative.pathOwnership,
            permittedNewOwnership: transactionOwnership
        ) else {
            throw CredentialExchangeError.authoritativeStateMismatch
        }
        if authoritative.accounts == currentAccounts {
            return
        }
        if transitionMatches(record: record, before: nil, after: authoritative.accounts),
           authoritative.generation < UInt64.max,
           accountSnapshotChangeIsSafe(from: authoritative.accounts, to: currentAccounts) {
            completedState.setState(CredentialCompletedProviderState(
                provider: record.event.provider,
                generation: authoritative.generation + 1,
                accounts: currentAccounts,
                pathOwnership: authoritative.pathOwnership
            ))
            try completedStateStore.save(completedState)
            return
        }
        guard authoritative.generation < UInt64.max,
              transitionMatches(record: record, before: authoritative.accounts, after: currentAccounts) else {
            throw CredentialExchangeError.authoritativeStateMismatch
        }
        completedState.setState(CredentialCompletedProviderState(
            provider: record.event.provider,
            generation: authoritative.generation + 1,
            accounts: currentAccounts,
            pathOwnership: authoritative.pathOwnership
        ))
        try completedStateStore.save(completedState)
    }

    private func completedAccountSnapshot(
        for provider: AccountFailoverProvider
    ) throws -> [CredentialCompletedAccountState] {
        let descriptors = try credentialAccountDescriptors(for: provider)
        guard Set(descriptors.map(\.path)).count == descriptors.count else {
            throw CredentialExchangeError.sameLocation
        }
        let accounts = try descriptors.map { descriptor in
            CredentialCompletedAccountState(
                accountID: descriptor.id,
                credentialLocation: descriptor.location,
                credentialPath: descriptor.path,
                credentialIdentity: try fileOperator.identity(at: descriptor.path)
            )
        }
        guard Set(accounts.map(\.credentialIdentity)).count == accounts.count else {
            throw CredentialExchangeError.duplicateCredentialIdentity
        }
        guard Set(accounts.map(\.credentialIdentity.device)).count == 1 else {
            throw CredentialExchangeError.crossVolume
        }
        return accounts.sorted { $0.accountID.uuidString < $1.accountID.uuidString }
    }

    private func credentialAccountDescriptors(
        for provider: AccountFailoverProvider
    ) throws -> [(id: UUID, location: String?, path: String)] {
        switch provider {
        case .claudeCode:
            return try claudeAccounts.enabledAccounts.map {
                ($0.id, $0.configDirectory, try claudeFileCredentialPath(for: $0))
            }
        case .codexCli:
            return codexAccounts.enabledAccounts.map {
                ($0.id, $0.homeDirectory, Self.standardized(CodexHomeDirectory.authFilePath(for: $0)))
            }
        }
    }

    private func transitionMatches(
        record: CredentialFileExchangeRecord,
        before: [CredentialCompletedAccountState]?,
        after: [CredentialCompletedAccountState]
    ) -> Bool {
        let expectedAfter = [
            record.event.fromAccountID: CredentialCompletedAccountState(
                accountID: record.event.fromAccountID,
                credentialLocation: record.targetCredentialLocation,
                credentialPath: record.targetPath,
                credentialIdentity: record.sourceIdentity
            ),
            record.event.toAccountID: CredentialCompletedAccountState(
                accountID: record.event.toAccountID,
                credentialLocation: record.sourceCredentialLocation,
                credentialPath: record.sourcePath,
                credentialIdentity: record.targetIdentity
            ),
        ]
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.accountID, $0) })
        guard expectedAfter.allSatisfy({ afterByID[$0.key] == $0.value }) else { return false }
        guard let before else { return true }
        let expectedBefore = [
            record.event.fromAccountID: CredentialCompletedAccountState(
                accountID: record.event.fromAccountID,
                credentialLocation: record.sourceCredentialLocation,
                credentialPath: record.sourcePath,
                credentialIdentity: record.sourceIdentity
            ),
            record.event.toAccountID: CredentialCompletedAccountState(
                accountID: record.event.toAccountID,
                credentialLocation: record.targetCredentialLocation,
                credentialPath: record.targetPath,
                credentialIdentity: record.targetIdentity
            ),
        ]
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.accountID, $0) })
        guard expectedBefore.allSatisfy({ beforeByID[$0.key] == $0.value }) else { return false }
        let transactionIDs = Set(expectedBefore.keys)
        let beforeOtherIDs = Set(beforeByID.keys).subtracting(transactionIDs)
        let afterOtherIDs = Set(afterByID.keys).subtracting(transactionIDs)
        guard beforeOtherIDs.isSubset(of: afterOtherIDs) || afterOtherIDs.isSubset(of: beforeOtherIDs) else {
            return false
        }
        return beforeOtherIDs.intersection(afterOtherIDs).allSatisfy {
            beforeByID[$0] == afterByID[$0]
        }
    }

    private func accountSnapshotChangeIsSafe(
        from authoritative: [CredentialCompletedAccountState],
        to current: [CredentialCompletedAccountState]
    ) -> Bool {
        let authoritativeByID = Dictionary(uniqueKeysWithValues: authoritative.map { ($0.accountID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.accountID, $0) })
        let authoritativeIDs = Set(authoritativeByID.keys)
        let currentIDs = Set(currentByID.keys)
        guard authoritativeIDs.isSubset(of: currentIDs) || currentIDs.isSubset(of: authoritativeIDs) else {
            return false
        }
        return authoritativeIDs.intersection(currentIDs).allSatisfy {
            guard let before = authoritativeByID[$0], let after = currentByID[$0] else { return false }
            return before.accountID == after.accountID
                && before.credentialLocation == after.credentialLocation
                && before.credentialPath == after.credentialPath
        }
    }

    private func pathsRespectOwnership(
        _ accounts: [CredentialCompletedAccountState],
        history: [CredentialCompletedPathOwnership],
        permittedNewOwnership: [CredentialCompletedPathOwnership] = []
    ) -> Bool {
        let ownershipByPath = Dictionary(grouping: history, by: \.credentialPath)
        let permitted = Set(permittedNewOwnership)
        return accounts.allSatisfy { account in
            let ownership = CredentialCompletedPathOwnership(account: account)
            guard let priorOwners = ownershipByPath[account.credentialPath] else { return true }
            return priorOwners.contains(ownership) || permitted.contains(ownership)
        }
    }
}
