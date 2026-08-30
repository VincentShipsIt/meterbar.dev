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
    private static let maximumBytes = 64 * 1024
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load() throws -> CredentialFileExchangeRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumBytes else { throw CredentialExchangeError.journalWriteFailed }
        return try JSONDecoder().decode(CredentialFileExchangeRecord.self, from: data)
    }

    func save(_ record: CredentialFileExchangeRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumBytes else { throw CredentialExchangeError.journalWriteFailed }
        try Self.replaceDurably(data, at: fileURL)
        guard try load() == record else { throw CredentialExchangeError.journalWriteFailed }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard unlink(fileURL.path) == 0 else { throw CredentialExchangeError.atomicExchangeFailed(errno) }
        try Self.syncDirectory(fileURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CredentialExchangeError.journalWriteFailed
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(ServiceSupport.realHomeDirectory())/Library/Application Support")
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent("account-failover", isDirectory: true)
            .appendingPathComponent("transaction.json")
    }

    private static func replaceDurably(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try SecureFileWriter.ensurePrivateDirectory(directory)
        let staging = directory.appendingPathComponent(".transaction.\(UUID().uuidString).partial")
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
    private let transactionLock: CredentialExchangeProcessLocking
    private let keychainItemProbe: (String) -> Bool

    init(
        claudeAccounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        failoverSettings: AccountFailoverSettingsStore? = nil,
        fileOperator: CredentialFileOperating = DarwinCredentialFileOperator(),
        journal: CredentialExchangeJournaling? = nil,
        transactionLock: CredentialExchangeProcessLocking? = nil,
        keychainItemProbe: ((String) -> Bool)? = nil
    ) {
        self.claudeAccounts = claudeAccounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.failoverSettings = failoverSettings ?? .shared
        self.fileOperator = fileOperator
        self.journal = journal ?? DurableCredentialExchangeJournal()
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
            retainOwnership = true
            return record.event
        case (.committed, .swapped):
            try commitLogicalMapping(for: record)
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
        retainOwnership = true
    }

    func completeNotification(eventID: UUID) throws {
        let acquiredNow = try transactionLock.acquire()
        guard let record = try journal.load(),
              record.phase == .committed,
              record.event.id == eventID else {
            if acquiredNow { transactionLock.release() }
            throw CredentialExchangeError.notificationEventMismatch
        }
        try journal.clear()
        transactionLock.release()
    }

    private func credentialAccounts(for provider: AccountFailoverProvider) throws -> [(id: UUID, path: String)] {
        switch provider {
        case .claudeCode:
            return try claudeAccounts.enabledAccounts.map {
                ($0.id, try claudeFileCredentialPath(for: $0))
            }
        case .codexCli:
            return codexAccounts.enabledAccounts.map {
                ($0.id, Self.standardized(CodexHomeDirectory.authFilePath(for: $0)))
            }
        }
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
}
