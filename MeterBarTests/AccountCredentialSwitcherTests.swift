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
    func testIndependentSwitcherCannotDoubleSwapAcrossTransactionLock() async throws {
        let firstSuite = "AccountCredentialSwitcherTests.first.\(UUID().uuidString)"
        let secondSuite = "AccountCredentialSwitcherTests.second.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarTransactionLockTests-\(UUID().uuidString)", isDirectory: true)
        let journalURL = directory.appendingPathComponent("transaction.json")
        let completedStateURL = directory.appendingPathComponent("completed-state.json")
        let lockURL = directory.appendingPathComponent("transaction.lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let targetID = UUID()
        let fallback = CodexAccount(id: targetID, name: "Fallback", homeDirectory: "/provider/fallback")
        let persistedFallback = try JSONEncoder().encode([fallback])
        firstDefaults.set(persistedFallback, forKey: StorageKeys.codexCustomAccounts)
        secondDefaults.set(persistedFallback, forKey: StorageKeys.codexCustomAccounts)
        let firstAccounts = CodexAccountStore(userDefaults: firstDefaults)
        let secondAccounts = CodexAccountStore(userDefaults: secondDefaults)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let first = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: firstDefaults),
            codexAccounts: firstAccounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: firstDefaults),
            fileOperator: fileOperator,
            journal: DurableCredentialExchangeJournal(fileURL: journalURL),
            completedStateStore: DurableCredentialCompletedStateStore(fileURL: completedStateURL),
            transactionLock: CredentialExchangeProcessLock(fileURL: lockURL)
        )
        let second = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: secondDefaults),
            codexAccounts: secondAccounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: secondDefaults),
            fileOperator: fileOperator,
            journal: DurableCredentialExchangeJournal(fileURL: journalURL),
            completedStateStore: DurableCredentialCompletedStateStore(fileURL: completedStateURL),
            transactionLock: CredentialExchangeProcessLock(fileURL: lockURL)
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)

        try await first.switchCredentials(for: switchEvent)
        do {
            try await second.switchCredentials(for: switchEvent)
            XCTFail("Expected the independent switcher to contend")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .transactionLockContended)
        }
        XCTAssertEqual(fileOperator.exchangeCount, 1)

        try first.completeNotification(eventID: switchEvent.id)
        let completedState = try XCTUnwrap(
            DurableCredentialCompletedStateStore(fileURL: completedStateURL).load()?.state(for: .codexCli)
        )
        XCTAssertEqual(completedState.generation, 1)
        XCTAssertEqual(
            completedState.accounts.first(where: { $0.accountID == targetID })?.credentialPath,
            CodexHomeDirectory.authFilePath()
        )
        do {
            try await second.switchCredentials(for: switchEvent)
            XCTFail("Expected stale account metadata to fail closed after lock release")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .authoritativeStateMismatch)
        }
        XCTAssertEqual(fileOperator.exchangeCount, 1)
    }

    @MainActor
    func testAuthoritativeStateSafelyReconcilesFallbackAdditionAndRemoval() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fallbackID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let completedStateStore = TestCredentialCompletedStateStore()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal(),
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: fallbackID)
        try await switcher.switchCredentials(for: switchEvent)
        try switcher.completeNotification(eventID: switchEvent.id)

        accounts.addAccount(name: "New fallback", homeDirectory: "/provider/new")
        let addedID = try XCTUnwrap(accounts.customAccounts.first(where: { $0.id != fallbackID })?.id)
        fileOperator.seed("/provider/new/auth.json", identity: .c)
        XCTAssertTrue(switcher.eligibility(for: .codexCli).isEligible)
        let addedState = try XCTUnwrap(completedStateStore.state?.state(for: .codexCli))
        XCTAssertEqual(addedState.generation, 2)
        XCTAssertEqual(Set(addedState.accounts.map(\.accountID)), Set(accounts.enabledAccounts.map(\.id)))

        XCTAssertEqual(accounts.removeAccount(id: addedID), .updated)
        XCTAssertTrue(switcher.eligibility(for: .codexCli).isEligible)
        let removedState = try XCTUnwrap(completedStateStore.state?.state(for: .codexCli))
        XCTAssertEqual(removedState.generation, 3)
        XCTAssertEqual(Set(removedState.accounts.map(\.accountID)), Set(accounts.enabledAccounts.map(\.id)))
        XCTAssertTrue(removedState.pathOwnership.contains { $0.accountID == addedID })
        XCTAssertEqual(fileOperator.exchangeCount, 1)
    }

    @MainActor
    func testSameAccountPathCredentialRewriteRemainsEligibleAndCanSwitch() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fallbackID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let completedStateStore = TestCredentialCompletedStateStore()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal(),
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let fallbackEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: fallbackID)
        try await switcher.switchCredentials(for: fallbackEvent)
        try switcher.completeNotification(eventID: fallbackEvent.id)

        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .c)
        XCTAssertTrue(switcher.eligibility(for: .codexCli).isEligible)
        XCTAssertEqual(completedStateStore.state?.state(for: .codexCli)?.generation, 2)

        let switchBackEvent = event(provider: .codexCli, from: fallbackID, to: CodexAccount.defaultID)
        try await switcher.switchCredentials(for: switchBackEvent)
        try switcher.completeNotification(eventID: switchBackEvent.id)
        XCTAssertEqual(fileOperator.exchangeCount, 2)
    }

    @MainActor
    func testRewrittenThenRemovedFallbackPathCannotBeReassignedToNewAccountID() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Live fallback", homeDirectory: "/provider/live")
        accounts.addAccount(name: "Removable fallback", homeDirectory: "/provider/removable")
        let liveID = try XCTUnwrap(
            accounts.customAccounts.first(where: { $0.homeDirectory == "/provider/live" })?.id
        )
        let removedID = try XCTUnwrap(
            accounts.customAccounts.first(where: { $0.homeDirectory == "/provider/removable" })?.id
        )
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/live/auth.json", identity: .b)
        fileOperator.seed("/provider/removable/auth.json", identity: .c)
        let completedStateStore = TestCredentialCompletedStateStore()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: TestCredentialExchangeJournal(),
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let firstEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: liveID)
        try await switcher.switchCredentials(for: firstEvent)
        try switcher.completeNotification(eventID: firstEvent.id)

        fileOperator.seed("/provider/removable/auth.json", identity: .d)
        XCTAssertTrue(switcher.eligibility(for: .codexCli).isEligible)
        XCTAssertEqual(accounts.removeAccount(id: removedID), .updated)
        XCTAssertTrue(switcher.eligibility(for: .codexCli).isEligible)
        XCTAssertEqual(
            completedStateStore.state?.state(for: .codexCli)?.pathOwnership.contains {
                $0.accountID == removedID
            },
            true
        )
        accounts.addAccount(name: "Replacement UUID", homeDirectory: "/provider/removable")
        let replacementID = try XCTUnwrap(
            accounts.customAccounts.first(where: { $0.homeDirectory == "/provider/removable" })?.id
        )
        XCTAssertNotEqual(replacementID, removedID)

        XCTAssertFalse(switcher.eligibility(for: .codexCli).isEligible)
        do {
            try await switcher.switchCredentials(
                for: event(provider: .codexCli, from: liveID, to: replacementID)
            )
            XCTFail("Expected the removed provider-file binding to remain owned by its original account ID")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .authoritativeStateMismatch)
        }
        XCTAssertEqual(fileOperator.exchangeCount, 1)
    }

    @MainActor
    func testPendingNotificationDefersSafeAccountSetReconciliationUntilAck() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fallbackID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal()
        let completedStateStore = TestCredentialCompletedStateStore()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: fallbackID)
        try await switcher.switchCredentials(for: switchEvent)

        accounts.addAccount(name: "New fallback", homeDirectory: "/provider/new")
        fileOperator.seed("/provider/new/auth.json", identity: .c)
        XCTAssertFalse(switcher.eligibility(for: .codexCli).isEligible)
        XCTAssertEqual(completedStateStore.state?.state(for: .codexCli)?.generation, 1)

        try switcher.completeNotification(eventID: switchEvent.id)
        let completed = try XCTUnwrap(completedStateStore.state?.state(for: .codexCli))
        XCTAssertEqual(completed.generation, 2)
        XCTAssertEqual(Set(completed.accounts.map(\.accountID)), Set(accounts.enabledAccounts.map(\.id)))
        XCTAssertNil(journal.record)
        XCTAssertEqual(fileOperator.exchangeCount, 1)
    }

    @MainActor
    func testRemovingLiveTargetBeforeNotificationAckRetainsRecoverableWAL() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let fallbackID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal()
        let completedStateStore = TestCredentialCompletedStateStore()
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: fallbackID)
        try await switcher.switchCredentials(for: switchEvent)
        XCTAssertEqual(accounts.setEnabled(false, for: fallbackID), .updated)

        XCTAssertThrowsError(try switcher.completeNotification(eventID: switchEvent.id)) { error in
            XCTAssertEqual(error as? CredentialExchangeError, .authoritativeStateMismatch)
        }
        XCTAssertEqual(journal.record?.phase, .committed)
        XCTAssertEqual(fileOperator.exchangeCount, 1)

        XCTAssertEqual(accounts.setEnabled(true, for: fallbackID), .updated)
        let recoveredEvent = try await switcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, switchEvent)
        try switcher.completeNotification(eventID: switchEvent.id)
        XCTAssertNil(journal.record)
        XCTAssertEqual(fileOperator.exchangeCount, 1)
    }

    @MainActor
    func testCrashedProcessLockHolderReleasesOwnershipForDurableRecovery() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarCrashedTransactionLockTests-\(UUID().uuidString)", isDirectory: true)
        let journalURL = directory.appendingPathComponent("transaction.json")
        let completedStateURL = directory.appendingPathComponent("completed-state.json")
        let lockURL = directory.appendingPathComponent("transaction.lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let pendingEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        let record = CredentialFileExchangeRecord(
            event: pendingEvent,
            phase: .prepared,
            sourcePath: CodexHomeDirectory.authFilePath(),
            targetPath: "/provider/fallback/auth.json",
            sourceCredentialLocation: nil,
            targetCredentialLocation: "/provider/fallback",
            sourceIdentity: .a,
            targetIdentity: .b
        )
        let journal = DurableCredentialExchangeJournal(fileURL: journalURL)
        try journal.save(record)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(record.sourcePath, identity: .b)
        fileOperator.seed(record.targetPath, identity: .a)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: DurableCredentialCompletedStateStore(fileURL: completedStateURL),
            transactionLock: CredentialExchangeProcessLock(fileURL: lockURL)
        )
        let holder = try SpawnedCredentialExchangeLockHolder(lockURL: lockURL)
        defer { holder.terminate() }

        do {
            _ = try await switcher.recoverPendingTransactions()
            XCTFail("Expected recovery to contend with the independent process")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .transactionLockContended)
        }

        holder.terminate()
        let recoveredEvent = try await switcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, pendingEvent)
        let completedState = try XCTUnwrap(
            DurableCredentialCompletedStateStore(fileURL: completedStateURL).load()?.state(for: .codexCli)
        )
        XCTAssertEqual(completedState.generation, 1)
        XCTAssertEqual(
            completedState.accounts.first(where: { $0.accountID == targetID })?.credentialIdentity,
            .b
        )
        try switcher.completeNotification(eventID: pendingEvent.id)
        XCTAssertNil(try journal.load())
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
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock(),
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
            journal: TestCredentialExchangeJournal(),
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            journal: TestCredentialExchangeJournal(),
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            journal: TestCredentialExchangeJournal(),
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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

    @MainActor
    func testFreshCompletionReleasesItsLockWhenJournalClearFails() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = CodexAccountStore(userDefaults: defaults)
        accounts.addAccount(name: "Fallback", homeDirectory: "/provider/fallback")
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(CodexHomeDirectory.authFilePath(), identity: .a)
        fileOperator.seed("/provider/fallback/auth.json", identity: .b)
        let journal = TestCredentialExchangeJournal(clearError: TestFailure.injected)
        let completedStateStore = TestCredentialCompletedStateStore()
        let settings = AccountFailoverSettingsStore(userDefaults: defaults)
        let first = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: settings,
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        try await first.switchCredentials(for: switchEvent)
        let completionLock = TestCredentialExchangeProcessLock()
        let completion = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: CodexAccountStore(userDefaults: defaults),
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: completedStateStore,
            transactionLock: completionLock
        )
        XCTAssertThrowsError(try completion.completeNotification(eventID: switchEvent.id))
        XCTAssertFalse(completionLock.isHeld)
        XCTAssertEqual(journal.record?.phase, .committed)
    }

    @MainActor
    func testFailedAuthoritativeStateAdvanceLeavesCommittedWALForRecovery() async throws {
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
        let completedStateStore = TestCredentialCompletedStateStore(failSaveAttempt: 2)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: completedStateStore,
            transactionLock: TestCredentialExchangeProcessLock()
        )
        let switchEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)

        do {
            try await switcher.switchCredentials(for: switchEvent)
            XCTFail("Expected the authoritative state advance to fail")
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(fileOperator.exchangeCount, 1)
        XCTAssertEqual(journal.record?.phase, .committed)
        XCTAssertEqual(completedStateStore.state?.state(for: .codexCli)?.generation, 0)

        completedStateStore.failSaveAttempt = nil
        let recoveredEvent = try await switcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, switchEvent)
        XCTAssertEqual(completedStateStore.state?.state(for: .codexCli)?.generation, 1)
        XCTAssertEqual(fileOperator.exchangeCount, 1)
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
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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

    @MainActor
    func testSameStoreRecoveryRetriesPersistenceAfterInMemorySwapFailedReadback() async throws {
        let suite = "AccountCredentialSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var persistenceAttempts = 0
        let targetDirectory = "/provider/target"
        let accounts = CodexAccountStore(
            userDefaults: defaults,
            credentialPersistenceBarrier: { persistedDefaults in
                persistenceAttempts += 1
                if persistenceAttempts == 1 {
                    persistedDefaults.removeObject(forKey: StorageKeys.codexCustomAccounts)
                    _ = persistedDefaults.synchronize()
                    return false
                }
                return persistedDefaults.synchronize()
            }
        )
        accounts.addAccount(name: "Target", homeDirectory: targetDirectory)
        let targetID = try XCTUnwrap(accounts.customAccounts.first?.id)
        let pendingEvent = event(provider: .codexCli, from: CodexAccount.defaultID, to: targetID)
        let record = CredentialFileExchangeRecord(
            event: pendingEvent,
            phase: .prepared,
            sourcePath: CodexHomeDirectory.authFilePath(),
            targetPath: "\(targetDirectory)/auth.json",
            sourceCredentialLocation: nil,
            targetCredentialLocation: targetDirectory,
            sourceIdentity: .a,
            targetIdentity: .b
        )
        let journal = TestCredentialExchangeJournal()
        journal.record = record
        let fileOperator = TestCredentialFileOperator()
        fileOperator.seed(record.sourcePath, identity: .b)
        fileOperator.seed(record.targetPath, identity: .a)
        let switcher = LiveAccountCredentialSwitcher(
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: defaults),
            codexAccounts: accounts,
            failoverSettings: AccountFailoverSettingsStore(userDefaults: defaults),
            fileOperator: fileOperator,
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
        )

        do {
            _ = try await switcher.recoverPendingTransactions()
            XCTFail("Expected the first persistence readback to fail")
        } catch {
            XCTAssertEqual(error as? CredentialExchangeError, .recoveryRequired)
        }
        XCTAssertEqual(persistenceAttempts, 1)
        XCTAssertEqual(journal.record?.phase, .prepared)

        let recoveredEvent = try await switcher.recoverPendingTransactions()
        XCTAssertEqual(recoveredEvent, pendingEvent)
        XCTAssertEqual(persistenceAttempts, 2)
        XCTAssertEqual(journal.record?.phase, .committed)
        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(
            reloaded.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            targetDirectory
        )
        XCTAssertNil(reloaded.accounts.first(where: { $0.id == targetID })?.homeDirectory)
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

    func testDurableCompletedStateRoundTripsMetadataAcrossFreshInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterBarFailoverCompletedStateTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("completed-state.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID()
        let stored = CredentialCompletedState(providers: [
            CredentialCompletedProviderState(
                provider: .codexCli,
                generation: 7,
                accounts: [
                    CredentialCompletedAccountState(
                        accountID: accountID,
                        credentialLocation: "/provider/a",
                        credentialPath: "/provider/a/auth.json",
                        credentialIdentity: .a
                    ),
                ]
            ),
        ])

        try DurableCredentialCompletedStateStore(fileURL: fileURL).save(stored)

        let freshStore = DurableCredentialCompletedStateStore(fileURL: fileURL)
        XCTAssertEqual(try freshStore.load(), stored)
        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(serialized.contains(accountID.uuidString))
        XCTAssertTrue(serialized.contains("pathOwnership"))
        XCTAssertFalse(serialized.contains("bindingHistory"))
        XCTAssertFalse(serialized.contains("source-credential"))
        XCTAssertFalse(serialized.contains("target-credential"))
        XCTAssertFalse(serialized.contains("Work"))

        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any]
        )
        var providers = try XCTUnwrap(legacyJSON["providers"] as? [[String: Any]])
        providers[0]["bindingHistory"] = providers[0]["accounts"]
        providers[0].removeValue(forKey: "pathOwnership")
        legacyJSON["providers"] = providers
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: fileURL, options: .atomic)
        let migrated = try XCTUnwrap(freshStore.load()?.state(for: .codexCli))
        XCTAssertEqual(
            Set(migrated.pathOwnership),
            Set(migrated.accounts.map(CredentialCompletedPathOwnership.init(account:)))
        )
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
            journal: DurableCredentialExchangeJournal(fileURL: fileURL),
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
            journal: journal,
            completedStateStore: TestCredentialCompletedStateStore(),
            transactionLock: TestCredentialExchangeProcessLock()
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
    static let d = Self(device: 1, inode: 40)
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

nonisolated private final class TestCredentialCompletedStateStore: CredentialCompletedStateStoring {
    var state: CredentialCompletedState?
    var failSaveAttempt: Int?
    private(set) var saveAttempts = 0

    init(failSaveAttempt: Int? = nil) {
        self.failSaveAttempt = failSaveAttempt
    }

    func load() throws -> CredentialCompletedState? { state }

    func save(_ state: CredentialCompletedState) throws {
        saveAttempts += 1
        if saveAttempts == failSaveAttempt { throw TestFailure.injected }
        self.state = state
    }
}

nonisolated private final class TestCredentialExchangeProcessLock: CredentialExchangeProcessLocking {
    private(set) var isHeld = false

    func acquire() throws -> Bool {
        let acquiredNow = !isHeld
        isHeld = true
        return acquiredNow
    }

    func release() {
        isHeld = false
    }
}

nonisolated private final class SpawnedCredentialExchangeLockHolder {
    private let process: Process
    private var hasTerminated = false

    init(lockURL: URL) throws {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, sys, time
            with open(sys.argv[1], "a") as lock_file:
                fcntl.flock(lock_file, fcntl.LOCK_EX)
                sys.stdout.buffer.write(bytes([1]))
                sys.stdout.buffer.flush()
                while True:
                    time.sleep(60)
            """,
            lockURL.path,
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let ready = output.fileHandleForReading.readData(ofLength: 1)
        guard ready == Data([1]) else {
            process.waitUntilExit()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            throw SpawnedCredentialExchangeLockHolderError.failed(
                status: process.terminationStatus,
                stderr: String(data: stderr, encoding: .utf8) ?? "unreadable stderr"
            )
        }
        self.process = process
    }

    func terminate() {
        guard !hasTerminated else { return }
        hasTerminated = true
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit { terminate() }
}

nonisolated private enum SpawnedCredentialExchangeLockHolderError: LocalizedError {
    case failed(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .failed(status, stderr):
            "spawned credential-lock holder exited with status \(status): \(stderr)"
        }
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
