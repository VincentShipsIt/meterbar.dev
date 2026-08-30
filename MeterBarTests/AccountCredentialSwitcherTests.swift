import Foundation
import XCTest
@testable import MeterBar

final class AccountCredentialSwitcherTests: XCTestCase {
    func testCoordinatorUsesInjectedCredentialSwitcherAndNeverNeedsKeychainInTests() async throws {
        let preferred = UUID()
        let fallback = UUID()
        let switcher = RecordingCredentialSwitcher()

        try await switcher.switchCredentials(for: event(provider: .claudeCode, from: preferred, to: fallback))

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

    func testDuplicateInodeIdentityIsRejectedBeforeJournalOrMutation() {
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .a)

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal)) { error in
            XCTAssertEqual(error as? CredentialExchangeError, .duplicateCredentialIdentity)
        }
        XCTAssertNil(journal.record)
        XCTAssertEqual(fileOperator.exchangeCount, 0)
    }

    func testExistingJournalIsRejectedBeforeAnyNewMutation() {
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        fileOperator.seed("/provider/a", identity: .a)
        fileOperator.seed("/provider/b", identity: .b)
        journal.record = record(
            sourcePath: "/provider/a",
            targetPath: "/provider/b",
            phase: .prepared
        )

        XCTAssertThrowsError(try exchange(fileOperator: fileOperator, journal: journal)) { error in
            XCTAssertEqual(error as? CredentialExchangeError, .journalAlreadyPending)
        }
        XCTAssertEqual(fileOperator.exchangeCount, 0)
    }

    @MainActor
    func testSwitcherRejectsPreparedJournalWithoutRecoveringOrReplacingIt() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal()
        let existingRecord = CredentialFileExchangeRecord(
            event: event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID),
            phase: .prepared,
            sourcePath: CodexHomeDirectory.authFilePath(),
            targetPath: "/provider/fallback/auth.json",
            sourceCredentialLocation: nil,
            targetCredentialLocation: "/provider/fallback",
            sourceIdentity: .a,
            targetIdentity: .b
        )
        journal.record = existingRecord
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal
        )

        do {
            try await switcher.switchCredentials(
                for: event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
            )
            XCTFail("Expected a pending journal to reject the switch")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .journalAlreadyPending)
        }
        XCTAssertEqual(journal.record, existingRecord)
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

    @MainActor
    func testCanonicalLiveAccountDoesNotChangeWhenFallbackOrderChanges() throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal()
        )

        XCTAssertEqual(try switcher.liveAccountID(for: .codexCli), CodexAccount.defaultID)
        accounts.moveAccounts(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(try switcher.liveAccountID(for: .codexCli), CodexAccount.defaultID)
    }

    @MainActor
    func testAmbiguousCanonicalLiveMappingIsIneligible() throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Duplicate", homeDirectory: CodexHomeDirectory.path())
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal()
        )

        let eligibility = switcher.eligibility(for: .codexCli)

        XCTAssertFalse(eligibility.isEligible)
        XCTAssertEqual(eligibility.reason?.contains("Exactly one enabled account"), true)
        XCTAssertThrowsError(try switcher.liveAccountID(for: .codexCli))
    }

    @MainActor
    func testDisableEditAndRemovalNeverRetargetLiveMetadataByAccountOrder() throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fallbackID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        settings.setActiveAccountID(CodexAccount.defaultID, for: .codexCli)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        fileOperator.seed("/provider/edited/auth.json", identity: .c)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: settings,
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal()
        )

        XCTAssertEqual(accounts.setEnabled(false, for: CodexAccount.defaultID), .updated)
        XCTAssertThrowsError(try switcher.liveAccountID(for: .codexCli))
        XCTAssertEqual(settings.activeAccountIDs[.codexCli], CodexAccount.defaultID)

        XCTAssertEqual(accounts.setEnabled(true, for: CodexAccount.defaultID), .updated)
        accounts.updateAccount(id: CodexAccount.defaultID, name: "Edited", homeDirectory: "/provider/edited")
        XCTAssertThrowsError(try switcher.liveAccountID(for: .codexCli))
        XCTAssertEqual(settings.activeAccountIDs[.codexCli], CodexAccount.defaultID)

        accounts.updateAccount(id: CodexAccount.defaultID, name: "Default", homeDirectory: "")
        XCTAssertEqual(accounts.removeAccount(id: fallbackID), .updated)
        XCTAssertEqual(try switcher.liveAccountID(for: .codexCli), CodexAccount.defaultID)
        XCTAssertEqual(settings.activeAccountIDs[.codexCli], CodexAccount.defaultID)
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
    func testSuccessfulSwitchRetainsCommittedNotificationOutboxUntilAcknowledged() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceDirectory = CodexHomeDirectory.path()
        let targetDirectory = "/provider/codex-target"
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed("\(sourceDirectory)/auth.json", identity: .a)
        fileOperator.seed("\(targetDirectory)/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: settings,
            fileOperator: fileOperator,
            journal: journal
        )

        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        try await switcher.switchCredentials(for: switchEvent)

        XCTAssertEqual(settings.activeAccountIDs[.codexCli], targetID)
        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertNil(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory)
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
        XCTAssertEqual(journal.record?.phase, .committed)
        XCTAssertEqual(journal.record?.event, switchEvent)

        try switcher.completeNotification(eventID: switchEvent.id)
        XCTAssertNil(journal.record)
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
        let sourceDirectory = CodexHomeDirectory.path()
        let targetDirectory = "/provider/codex-target"
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        let pendingEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        let record = CredentialFileExchangeRecord(
            event: pendingEvent,
            phase: .prepared,
            sourcePath: "\(sourceDirectory)/auth.json",
            targetPath: "\(targetDirectory)/auth.json",
            sourceCredentialLocation: nil,
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

        let recoveredEvent = try await switcher.recoverPendingTransactions()

        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertNil(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory)
        XCTAssertEqual(settings.activeAccountIDs[.codexCli], targetID)
        XCTAssertEqual(recoveredEvent, pendingEvent)
        XCTAssertEqual(journal.record?.phase, .committed)
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
            event: event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID),
            phase: .prepared,
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

        let recoveredEvent = try await switcher.recoverPendingTransactions()

        XCTAssertEqual(
            accounts.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            "/provider/source"
        )
        XCTAssertEqual(accounts.accounts.first(where: { $0.id == targetID })?.homeDirectory, "/provider/target")
        XCTAssertNil(recoveredEvent)
        XCTAssertNil(journal.record)
    }

    @MainActor
    func testFreshStoreRecoveryRepairsDefaultSidePersistedBeforeCustomSide() async throws {
        try await assertFreshStorePartialRecovery(defaultSidePersisted: true)
    }

    @MainActor
    func testFreshStoreRecoveryRepairsCustomSidePersistedBeforeDefaultSide() async throws {
        try await assertFreshStorePartialRecovery(defaultSidePersisted: false)
    }

    func testDurableJournalRoundTripsAcrossFreshInstancesWithoutCredentialPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarFailoverJournalTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("transaction.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stored = record(sourcePath: "/provider/a", targetPath: "/provider/b", phase: .committed)

        try DurableCredentialExchangeJournal(fileURL: fileURL).save(stored)

        XCTAssertEqual(try DurableCredentialExchangeJournal(fileURL: fileURL).load(), stored)
        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("source-credential"))
        XCTAssertFalse(serialized.contains("target-credential"))

        try DurableCredentialExchangeJournal(fileURL: fileURL).clear()
        XCTAssertNil(try DurableCredentialExchangeJournal(fileURL: fileURL).load())
    }

    @MainActor
    func testFreshProcessRecoversCommittedSwitchAndNotificationOutbox() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarCommittedRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("transaction.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let targetDirectory = "/provider/target"
        let originalStore = CodexAccountStore(userDefaults: defaults)
        originalStore.addAccount(name: "Target", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(originalStore.customAccounts.first?.id)
        XCTAssertTrue(originalStore.exchangeCredentialLocations(
            from: CodexAccount.defaultID,
            to: targetID,
            expectedSource: nil,
            expectedTarget: targetDirectory
        ))
        let pendingEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        let committed = CredentialFileExchangeRecord(
            event: pendingEvent,
            phase: .committed,
            sourcePath: CodexHomeDirectory.authFilePath(),
            targetPath: "\(targetDirectory)/auth.json",
            sourceCredentialLocation: nil,
            targetCredentialLocation: targetDirectory,
            sourceIdentity: .a,
            targetIdentity: .b
        )
        try DurableCredentialExchangeJournal(fileURL: fileURL).save(committed)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(committed.sourcePath, identity: .b)
        fileOperator.seed(committed.targetPath, identity: .a)

        let freshSwitcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: DurableCredentialExchangeJournal(fileURL: fileURL)
        )

        let recoveredEvent = try await freshSwitcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, pendingEvent)
        XCTAssertEqual(try freshSwitcher.liveAccountID(for: .codexCli), targetID)
        try freshSwitcher.completeNotification(eventID: pendingEvent.id)
        XCTAssertNil(try DurableCredentialExchangeJournal(fileURL: fileURL).load())
        XCTAssertEqual(Set(fileOperator.identities.values), [.a, .b])
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
            event: event(provider: .codexCli, from: UUID(), to: UUID()),
            sourcePath: sourcePath,
            targetPath: targetPath,
            sourceCredentialLocation: sourceLocation,
            targetCredentialLocation: targetLocation
        )
    }

    private func record(
        sourcePath: String,
        targetPath: String,
        phase: CredentialFileExchangePhase
    ) -> CredentialFileExchangeRecord {
        CredentialFileExchangeRecord(
            event: event(provider: .codexCli, from: UUID(), to: UUID()),
            phase: phase,
            sourcePath: sourcePath,
            targetPath: targetPath,
            sourceCredentialLocation: "/provider/a",
            targetCredentialLocation: "/provider/b",
            sourceIdentity: .a,
            targetIdentity: .b
        )
    }

    @MainActor
    private func assertFreshStorePartialRecovery(defaultSidePersisted: Bool) async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let targetDirectory = "/provider/target"
        let initialStore = CodexAccountStore(userDefaults: defaults)
        initialStore.addAccount(name: "Target", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(initialStore.customAccounts.first?.id)

        if defaultSidePersisted {
            defaults.set(targetDirectory, forKey: StorageKeys.codexDefaultHomeDirectory)
        } else {
            var partialCustomAccounts = initialStore.customAccounts
            partialCustomAccounts[0].homeDirectory = nil
            defaults.set(try JSONEncoder().encode(partialCustomAccounts), forKey: StorageKeys.codexCustomAccounts)
        }

        let freshStore = CodexAccountStore(userDefaults: defaults)
        let fileOperator = TestCredentialFileOperator()
        let journal = TestCredentialExchangeJournal()
        let pendingEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        journal.record = CredentialFileExchangeRecord(
            event: pendingEvent,
            phase: .prepared,
            sourcePath: CodexHomeDirectory.authFilePath(),
            targetPath: "\(targetDirectory)/auth.json",
            sourceCredentialLocation: nil,
            targetCredentialLocation: targetDirectory,
            sourceIdentity: .a,
            targetIdentity: .b
        )
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .b)
        fileOperator.seed("\(targetDirectory)/auth.json", identity: .a)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: freshStore,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal
        )

        let recoveredEvent = try await switcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, pendingEvent)
        XCTAssertEqual(
            freshStore.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertNil(freshStore.accounts.first(where: { $0.id == targetID })?.homeDirectory)

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(
            reloaded.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertNil(reloaded.accounts.first(where: { $0.id == targetID })?.homeDirectory)
    }

    private func event(
        provider: AccountFailoverProvider,
        from: UUID,
        to: UUID
    ) -> AccountFailoverEvent {
        AccountFailoverEvent(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 99)),
            provider: provider,
            fromAccountID: from,
            fromAccountName: "Source",
            toAccountID: to,
            toAccountName: "Target",
            reason: .activeAccountDepleted,
            timestamp: Date(timeIntervalSince1970: 123)
        )
    }
}

private enum TestFailure: Error { case injected }

private extension CredentialFileIdentity {
    static let a = Self(device: 1, inode: 10)
    static let b = Self(device: 1, inode: 20)
    static let c = Self(device: 1, inode: 30)
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

    func switchCredentials(for event: AccountFailoverEvent) async throws {
        calls.append(AccountCredentialSwitch(
            provider: event.provider,
            fromAccountID: event.fromAccountID,
            toAccountID: event.toAccountID
        ))
    }
}
