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
}
