import Foundation
import XCTest
@testable import MeterBar

final class AccountCredentialSwitcherTests: XCTestCase {
    func testCoordinatorUsesInjectedCredentialSwitcherAndNeverNeedsKeychainInTests() async throws {
        let preferred = UUID()
        let fallback = UUID()
        let switcher = RecordingCredentialSwitcher()

        try await switcher.switchCredentials(provider: .claudeCode, from: preferred, to: fallback)

        XCTAssertEqual(
            switcher.calls,
            [AccountCredentialSwitch(provider: .claudeCode, fromAccountID: preferred, toAccountID: fallback)]
        )
    }

    func testAtomicExchangeSwapsIdentitiesAndNeverReadsCredentialPayloads() throws {
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .b)

        let record = try CredentialFileExchangeTransaction.prepareAndExchange(
            request(sourcePath: "/provider/a", targetPath: "/provider/b"),
            fileOperator: fileOperator,
            journal: journal
        )

        XCTAssertEqual(try CredentialFileExchangeTransaction.state(of: record, fileOperator: fileOperator), .swapped)
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
        XCTAssertEqual(journal.record, record)
    }

    func testDarwinRenameSwapExchangesProviderFilesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarAtomicCredentialTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source-auth.json")
        let target = directory.appendingPathComponent("target-auth.json")
        try Data("source-credential".utf8).write(to: source)
        try Data("target-credential".utf8).write(to: target)
        let journal = TestCredentialExchangeJournal()

        _ = try CredentialFileExchangeTransaction.prepareAndExchange(
            request(
                sourcePath: source.path,
                targetPath: target.path,
                sourceLocation: directory.path,
                targetLocation: directory.path
            ),
            fileOperator: DarwinCredentialFileOperator(),
            journal: journal
        )

        XCTAssertEqual(try Data(contentsOf: source), Data("target-credential".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("source-credential".utf8))
    }

    func testCrossVolumeLayoutIsRejectedBeforeJournalOrMutation() {
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: CredentialFileIdentity(device: 2, inode: 20))

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal)) { error in
            XCTAssertEqual(error as? CredentialExchangeError, .crossVolume)
        }
        XCTAssertNil(journal.record)
        XCTAssertEqual(fileOperator.exchangeCount, 0)
    }

    @MainActor
    func testClaudeKeychainLayoutIsExplicitlyIneligibleWithoutTouchingKeychain() throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = ClaudeCodeAccountStore(userDefaults: defaults)
        accounts.updateAccount(
            id: ClaudeCodeAccount.defaultID,
            name: ClaudeCodeAccount.defaultName,
            configDirectory: "/provider/claude-source"
        )
        accounts.addAccount(name: "Fallback", configDirectory: "/provider/claude-target")
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: accounts,
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: TestCredentialFileOperator(),
            journal: TestCredentialExchangeJournal(),
            keychainItemProbe: { _ in true }
        )

        let eligibility = switcher.eligibility(for: .claudeCode)

        XCTAssertFalse(eligibility.isEligible)
        XCTAssertEqual(eligibility.reason?.contains("no atomic multi-item transaction"), true)
    }

    func testJournalFailureHappensBeforeAnyCredentialMutation() {
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal(saveError: TestFailure.injected)
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .b)

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal))
        XCTAssertEqual(fileOperator.identities["/provider/a"], .a)
        XCTAssertEqual(fileOperator.identities["/provider/b"], .b)
        XCTAssertEqual(fileOperator.exchangeCount, 0)
    }

    func testAtomicExchangeFailurePreservesBothCredentialsAndOriginalMapping() {
        let fileOperator = TestCredentialFileOperator(failure: .beforeExchange)
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .b)

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal))
        XCTAssertEqual(fileOperator.identities["/provider/a"], .a)
        XCTAssertEqual(fileOperator.identities["/provider/b"], .b)
        XCTAssertNotNil(journal.record)
    }

    @MainActor
    func testJournalClearFailureAfterCommitDoesNotMisreportSuccessfulExchange() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceDirectory = "/provider/codex-source"
        let targetDirectory = "/provider/codex-target"
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.updateAccount(
            id: CodexAccount.defaultID,
            name: CodexAccount.defaultName,
            homeDirectory: sourceDirectory
        )
        accounts.addAccount(name: "Fallback", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed("\(sourceDirectory)/auth.json", identity: .a)
        fileOperator.seed("\(targetDirectory)/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal(clearError: TestFailure.injected)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: settings,
            fileOperator: fileOperator,
            journal: journal
        )

        try await switcher.switchCredentials(
            provider: .codexCli,
            from: CodexAccount.defaultID,
            to: targetID
        )

        XCTAssertEqual(settings.activeAccountIDs[.codexCli], targetID)
        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertEqual(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory, sourceDirectory)
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
        XCTAssertNotNil(journal.record)
    }

    func testCrashImmediatelyAfterAtomicExchangeLeavesBothCredentialsRecoverablySwapped() throws {
        let fileOperator = TestCredentialFileOperator(failure: .afterExchange)
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .b)

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal))

        let record = try XCTUnwrap(journal.record)
        XCTAssertEqual(try CredentialFileExchangeTransaction.state(of: record, fileOperator: fileOperator), .swapped)
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
    }

    @MainActor
    func testStartupRecoveryCompletesLogicalMappingAfterCrashFollowingSwap() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceDirectory = "/provider/codex-source"
        let targetDirectory = "/provider/codex-target"
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.updateAccount(
            id: CodexAccount.defaultID,
            name: CodexAccount.defaultName,
            homeDirectory: sourceDirectory
        )
        accounts.addAccount(name: "Fallback", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        let record = CredentialFileExchangeRecord(
            provider: .codexCli,
            sourceAccountID: CodexAccount.defaultID,
            targetAccountID: targetID,
            sourcePath: "\(sourceDirectory)/auth.json",
            targetPath: "\(targetDirectory)/auth.json",
            sourceCredentialLocation: sourceDirectory,
            targetCredentialLocation: targetDirectory,
            sourceIdentity: .a,
            targetIdentity: .b
        )
        journal.record = record
        fileOperator.seed(record.sourcePath, identity: .b)
        fileOperator.seed(record.targetPath, identity: .a)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: settings,
            fileOperator: fileOperator,
            journal: journal
        )

        try await switcher.recoverPendingTransactions()

        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertEqual(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory, sourceDirectory)
        XCTAssertEqual(settings.activeAccountIDs[.codexCli], targetID)
        XCTAssertNil(journal.record)
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
    }

    @MainActor
    func testStartupRecoveryAfterJournalButBeforeSwapLeavesLogicalMappingUntouched() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.updateAccount(id: CodexAccount.defaultID, name: "Source", homeDirectory: "/provider/source")
        accounts.addAccount(name: "Target", homeDirectory: "/provider/target")
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        let record = CredentialFileExchangeRecord(
            provider: .codexCli,
            sourceAccountID: CodexAccount.defaultID,
            targetAccountID: targetID,
            sourcePath: "/provider/source/auth.json",
            targetPath: "/provider/target/auth.json",
            sourceCredentialLocation: "/provider/source",
            targetCredentialLocation: "/provider/target",
            sourceIdentity: .a,
            targetIdentity: .b
        )
        journal.record = record
        fileOperator.seed(record.sourcePath, identity: .a)
        fileOperator.seed(record.targetPath, identity: .b)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal
        )

        try await switcher.recoverPendingTransactions()

        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            "/provider/source"
        )
        XCTAssertEqual(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory, "/provider/target")
        XCTAssertNil(journal.record)
    }

    private func exchange(
        fileOperator: TestCredentialFileOperator,
        journal: TestCredentialExchangeJournal
    ) throws -> CredentialFileExchangeRecord {
        try CredentialFileExchangeTransaction.prepareAndExchange(
            request(sourcePath: "/provider/a", targetPath: "/provider/b"),
            fileOperator: fileOperator,
            journal: journal
        )
    }

    private func request(
        sourcePath: String,
        targetPath: String,
        sourceLocation: String? = "/provider/a",
        targetLocation: String? = "/provider/b"
    ) -> CredentialFileExchangeRequest {
        CredentialFileExchangeRequest(
            provider: .codexCli,
            sourceAccountID: UUID(),
            targetAccountID: UUID(),
            sourcePath: sourcePath,
            targetPath: targetPath,
            sourceCredentialLocation: sourceLocation,
            targetCredentialLocation: targetLocation
        )
    }
}

private enum TestFailure: Error { case injected }

private extension CredentialFileIdentity {
    static let a = Self(device: 1, inode: 10)
    static let b = Self(device: 1, inode: 20)
}

nonisolated private final class TestCredentialFileOperator: CredentialFileOperating {
    enum Failure { case beforeExchange, afterExchange }

    private(set) var identities: [String: CredentialFileIdentity] = [:]
    private(set) var exchangeCount = 0
    private let failure: Failure?

    init(failure: Failure? = nil) { self.failure = failure }

    func seed(_ path: String, identity: CredentialFileIdentity) {
        identities[path] = identity
    }

    func identity(at path: String) throws -> CredentialFileIdentity {
        guard let identity = identities[path] else { throw CredentialExchangeError.missingSourceCredential }
        return identity
    }

    func atomicallyExchange(_ sourcePath: String, _ targetPath: String) throws {
        exchangeCount += 1
        if failure == .beforeExchange { throw TestFailure.injected }
        let source = identities[sourcePath]
        identities[sourcePath] = identities[targetPath]
        identities[targetPath] = source
        if failure == .afterExchange { throw TestFailure.injected }
    }
}

nonisolated private final class TestCredentialExchangeJournal: CredentialExchangeJournaling {
    var record: CredentialFileExchangeRecord?
    private let saveError: Error?
    private let clearError: Error?

    init(saveError: Error? = nil, clearError: Error? = nil) {
        self.saveError = saveError
        self.clearError = clearError
    }

    func load() throws -> CredentialFileExchangeRecord? { record }

    func save(_ record: CredentialFileExchangeRecord) throws {
        if let saveError { throw saveError }
        self.record = record
    }

    func clear() throws {
        if let clearError { throw clearError }
        record = nil
    }
}

private final class RecordingCredentialSwitcher: AccountCredentialSwitching {
    private(set) var calls: [AccountCredentialSwitch] = []

    func switchCredentials(provider: AccountFailoverProvider, from: UUID, to: UUID) async throws {
        calls.append(AccountCredentialSwitch(provider: provider, fromAccountID: from, toAccountID: to))
    }
}
