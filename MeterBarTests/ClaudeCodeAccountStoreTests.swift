import XCTest
@testable import MeterBar

final class ClaudeCodeAccountStoreTests: XCTestCase {

    // MARK: Internal

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeCodeAccountStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultProfileLabelCanBeEditedAndPersists() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)

        store.updateAccount(
            id: ClaudeCodeAccount.defaultID,
            name: "shipshitdev",
            configDirectory: nil
        )

        XCTAssertEqual(store.accounts.first?.name, "shipshitdev")

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accounts.first?.name, "shipshitdev")
    }

    func testCustomProfileCanBeEditedAndPersists() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "genfeed.ai", configDirectory: "/tmp/old-claude-profile")

        guard let account = store.customAccounts.first else {
            XCTFail("Expected a custom Claude account")
            return
        }

        store.updateAccount(
            id: account.id,
            name: "genfeedai",
            configDirectory: "/tmp/genfeed-claude-profile"
        )

        XCTAssertEqual(store.customAccounts.first?.name, "genfeedai")
        XCTAssertEqual(store.customAccounts.first?.configDirectory, "/tmp/genfeed-claude-profile")

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.customAccounts.first?.name, "genfeedai")
        XCTAssertEqual(reloaded.customAccounts.first?.configDirectory, "/tmp/genfeed-claude-profile")
    }

    func testCustomProfileCanBeRemoved() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "genfeedai", configDirectory: "/tmp/genfeed-claude-profile")

        guard let account = store.customAccounts.first else {
            XCTFail("Expected a custom Claude account")
            return
        }

        store.removeAccount(id: account.id)

        XCTAssertTrue(store.customAccounts.isEmpty)

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.customAccounts.isEmpty)
    }

    func testDefaultProfileCannotBeRemoved() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)

        store.removeAccount(id: ClaudeCodeAccount.defaultID)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.id, ClaudeCodeAccount.defaultID)
    }

    func testInvalidCustomProfileEditIsIgnored() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "genfeedai", configDirectory: "/tmp/genfeed-claude-profile")

        guard let account = store.customAccounts.first else {
            XCTFail("Expected a custom Claude account")
            return
        }

        store.updateAccount(
            id: account.id,
            name: "renamed",
            configDirectory: "   "
        )

        XCTAssertEqual(store.customAccounts.first?.name, "genfeedai")
        XCTAssertEqual(store.customAccounts.first?.configDirectory, "/tmp/genfeed-claude-profile")
    }

    // MARK: Private

    private var suiteName: String!
    private var defaults: UserDefaults!

}
