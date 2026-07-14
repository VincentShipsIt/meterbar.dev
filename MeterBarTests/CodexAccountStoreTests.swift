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

    // MARK: - Enablement (mirrors ClaudeCodeAccountStore)

    func testAccountsAreEnabledByDefault() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/codex-work")
        XCTAssertTrue(store.defaultAccountIsEnabled)
        XCTAssertEqual(store.enabledAccounts.map(\.id), store.accounts.map(\.id))
    }

    func testDisablingDefaultProfilePersistsAndFiltersEnabled() {
        let store = CodexAccountStore(userDefaults: defaults)
        store.setEnabled(false, for: CodexAccount.defaultID)
        XCTAssertFalse(store.defaultAccountIsEnabled)
        XCTAssertFalse(store.enabledAccounts.contains { $0.id == CodexAccount.defaultID })

        let reloaded = CodexAccountStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.defaultAccountIsEnabled)
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

    func testLegacyCustomProfilesDecodeAsEnabled() {
        // A profile persisted before `isEnabled` existed (no key) decodes enabled.
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Legacy","homeDirectory":"/tmp/legacy"}]"#
        defaults.set(Data(legacy.utf8), forKey: StorageKeys.codexCustomAccounts)

        let store = CodexAccountStore(userDefaults: defaults)
        XCTAssertEqual(store.customAccounts.count, 1)
        XCTAssertTrue(store.customAccounts[0].isEnabled)
    }
}
