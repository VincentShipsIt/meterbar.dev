import XCTest
@testable import MeterBar

final class CodexAccountStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CodexAccountStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultProfileNeedsNoConfigurationAndLabelPersists() {
        let store = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(store.accounts, [.defaultAccount])

        store.updateAccount(id: CodexAccount.defaultID, name: "Personal", homeDirectory: nil)

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accounts.first?.name, "Personal")
        XCTAssertNil(reloaded.accounts.first?.homeDirectory)
    }

    func testDefaultProfileHomeDirectoryCanBeEditedClearedAndPersists() {
        let store = CodexAccountStore(userDefaults: defaults)

        store.updateAccount(
            id: CodexAccount.defaultID,
            name: "Personal",
            homeDirectory: "/tmp/old/../codex-personal"
        )

        XCTAssertEqual(store.accounts.first?.homeDirectory, "/tmp/codex-personal")
        XCTAssertEqual(
            CodexAccountStore(userDefaults: defaults).accounts.first?.homeDirectory,
            "/tmp/codex-personal"
        )

        store.updateAccount(
            id: CodexAccount.defaultID,
            name: "Personal",
            homeDirectory: "   "
        )

        XCTAssertNil(store.accounts.first?.homeDirectory)
        XCTAssertNil(defaults.object(forKey: StorageKeys.codexDefaultHomeDirectory))
    }

    func testCustomProfilesPersistIndependentHomesAndOrder() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        store.addAccount(name: "Personal", homeDirectory: "/tmp/codex-personal")

        store.moveAccounts(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accounts.map(\.name), ["Personal", CodexAccount.defaultName, "Work"])
        XCTAssertEqual(reloaded.customAccounts.map(\.homeDirectory), ["/tmp/codex-work", "/tmp/codex-personal"])
    }

    func testCustomProfileCanBeEditedAndRemovedWithoutRemovingDefault() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/old")
        let account = store.customAccounts[0]

        store.updateAccount(id: account.id, name: "Team", homeDirectory: "/tmp/new")
        XCTAssertEqual(store.customAccounts[0].name, "Team")
        XCTAssertEqual(store.customAccounts[0].homeDirectory, "/tmp/new")

        store.removeAccount(id: account.id)
        store.removeAccount(id: CodexAccount.defaultID)
        XCTAssertEqual(store.accounts.map(\.id), [CodexAccount.defaultID])
    }

    func testCustomProfileLabelCanBeEditedWithoutResupplyingHomeDirectory() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let account = store.customAccounts[0]

        store.updateAccount(id: account.id, name: "Team", homeDirectory: nil)

        XCTAssertEqual(store.customAccounts[0].name, "Team")
        XCTAssertEqual(store.customAccounts[0].homeDirectory, "/tmp/codex-work")
    }

    // MARK: - Enablement safety

    func testAccountsAreEnabledByDefault() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        XCTAssertTrue(store.defaultAccountIsEnabled)
        XCTAssertEqual(store.enabledAccounts.map(\.id), store.accounts.map(\.id))
    }

    func testOnlyEnabledProfileCannotBeDisabled() {
        let store = CodexAccountStore(userDefaults: defaults)

        XCTAssertEqual(
            store.setEnabled(false, for: CodexAccount.defaultID),
            .rejectedLastEnabledAccount
        )
        XCTAssertTrue(store.defaultAccountIsEnabled)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [CodexAccount.defaultID])
    }

    func testDefaultProfileCanLeaveActiveSetAfterAlternativeIsEnabled() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let workID = store.customAccounts[0].id

        XCTAssertEqual(store.setEnabled(false, for: CodexAccount.defaultID), .updated)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [workID])
        XCTAssertTrue(store.accounts.contains { $0.id == CodexAccount.defaultID })

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.defaultAccountIsEnabled)
        XCTAssertEqual(reloaded.enabledAccounts.map(\.id), [workID])
    }

    func testDisablingCustomProfilePersistsAndFiltersEnabled() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let account = store.customAccounts[0]

        store.setEnabled(false, for: account.id)
        XCTAssertFalse(store.enabledAccounts.contains { $0.id == account.id })

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.customAccounts[0].isEnabled)
        XCTAssertFalse(reloaded.enabledAccounts.contains { $0.id == account.id })
    }

    func testLastEnabledCustomProfileCannotBeDisabledOrRemoved() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let account = store.customAccounts[0]
        XCTAssertEqual(store.setEnabled(false, for: CodexAccount.defaultID), .updated)

        XCTAssertFalse(store.canDisableAccount(id: account.id))
        XCTAssertFalse(store.canRemoveAccount(id: account.id))
        XCTAssertEqual(store.setEnabled(false, for: account.id), .rejectedLastEnabledAccount)
        XCTAssertEqual(store.removeAccount(id: account.id), .rejectedLastEnabledAccount)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [account.id])
    }

    func testDisabledCustomProfileCanBeRemoved() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        let account = store.customAccounts[0]
        XCTAssertEqual(store.setEnabled(false, for: account.id), .updated)

        XCTAssertTrue(store.canRemoveAccount(id: account.id))
        XCTAssertEqual(store.removeAccount(id: account.id), .updated)
        XCTAssertTrue(store.customAccounts.isEmpty)
    }

    func testLegacyCustomProfilesDecodeAsEnabled() {
        // A profile persisted before `isEnabled` existed (no key) decodes enabled.
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Legacy","homeDirectory":"/tmp/legacy"}]"#
        defaults.set(Data(legacy.utf8), forKey: StorageKeys.codexCustomAccounts)

        let store = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(store.customAccounts.count, 1)
        XCTAssertTrue(store.customAccounts[0].isEnabled)
    }

    func testLegacyAllDisabledStateRestoresDefaultSentinel() throws {
        let custom = CodexAccount(
            id: UUID(),
            name: "Legacy",
            homeDirectory: "/tmp/legacy",
            isEnabled: false
        )
        defaults.set(try JSONEncoder().encode([custom]), forKey: StorageKeys.codexCustomAccounts)
        defaults.set(false, forKey: StorageKeys.codexDefaultAccountEnabled)

        let store = CodexAccountStore(userDefaults: defaults)

        XCTAssertTrue(store.defaultAccountIsEnabled)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [CodexAccount.defaultID])
        XCTAssertNil(defaults.object(forKey: StorageKeys.codexDefaultAccountEnabled))
    }

    func testCredentialLocationExchangePreservesLogicalIdentityAndPersists() throws {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let fallback = try XCTUnwrap(store.customAccounts.first)

        XCTAssertTrue(store.exchangeCredentialLocations(
            from: CodexAccount.defaultID,
            to: fallback.id,
            expectedSource: nil,
            expectedTarget: "/tmp/codex-fallback"
        ))

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(
            reloaded.accounts.first(where: { $0.id == CodexAccount.defaultID })?.homeDirectory,
            "/tmp/codex-fallback"
        )
        XCTAssertNil(reloaded.accounts.first(where: { $0.id == fallback.id })?.homeDirectory)
    }

    func testCredentialLocationExchangeRejectsAProfileChangedMidSwitch() throws {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Fallback", homeDirectory: "/tmp/codex-fallback")
        let fallback = try XCTUnwrap(store.customAccounts.first)
        store.updateAccount(id: fallback.id, name: fallback.name, homeDirectory: "/tmp/changed")

        XCTAssertFalse(store.exchangeCredentialLocations(
            from: CodexAccount.defaultID,
            to: fallback.id,
            expectedSource: nil,
            expectedTarget: "/tmp/codex-fallback"
        ))
    }
}
