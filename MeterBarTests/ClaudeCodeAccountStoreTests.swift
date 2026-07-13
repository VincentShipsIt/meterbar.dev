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

    func testDefaultConfigDirectoryFallsBackToClaudeUnderRealHome() {
        XCTAssertEqual(
            ClaudeCodeAccount.defaultConfigDirectory(environment: [:], realHomeDirectory: "/Users/tester"),
            "/Users/tester/.claude"
        )
    }

    func testDefaultConfigDirectoryHonorsAndExpandsEnvironmentOverride() {
        XCTAssertEqual(
            ClaudeCodeAccount.defaultConfigDirectory(
                environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.claude-work"
        )
        XCTAssertEqual(
            ClaudeCodeAccount.defaultConfigDirectory(
                environment: ["CLAUDE_CONFIG_DIR": " /Volumes/config/claude "],
                realHomeDirectory: "/Users/tester"
            ),
            "/Volumes/config/claude"
        )
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

    func testLegacyCustomProfileDefaultsToEnabled() throws {
        let id = UUID()
        let data = try XCTUnwrap(
            """
            [{"id":"\(id.uuidString)","name":"Legacy","configDirectory":"/tmp/legacy"}]
            """.data(using: .utf8)
        )
        defaults.set(data, forKey: StorageKeys.claudeCodeCustomAccounts)

        let store = ClaudeCodeAccountStore(userDefaults: defaults)

        XCTAssertEqual(store.customAccounts.first?.id, id)
        XCTAssertEqual(store.customAccounts.first?.isEnabled, true)
        XCTAssertEqual(store.enabledAccounts.map(\.id), [ClaudeCodeAccount.defaultID, id])
    }

    func testDefaultAndCustomProfileEnabledStatePersists() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", configDirectory: "/tmp/work")
        guard let customID = store.customAccounts.first?.id else {
            XCTFail("Expected a custom Claude account")
            return
        }

        store.setEnabled(false, for: ClaudeCodeAccount.defaultID)
        store.setEnabled(false, for: customID)

        XCTAssertTrue(store.enabledAccounts.isEmpty)
        XCTAssertEqual(store.accounts.map(\.isEnabled), [false, false])

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.enabledAccounts.isEmpty)
        XCTAssertEqual(reloaded.accounts.map(\.isEnabled), [false, false])

        reloaded.setEnabled(true, for: ClaudeCodeAccount.defaultID)
        reloaded.setEnabled(true, for: customID)
        let enabledReload = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertEqual(enabledReload.enabledAccounts.map(\.id), [ClaudeCodeAccount.defaultID, customID])
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

    func testAccountOrderCanMoveDefaultProfileAndPersists() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "shipshitdev", configDirectory: "/tmp/shipshitdev")
        store.addAccount(name: "genfeedai", configDirectory: "/tmp/genfeedai")

        let initialIDs = store.accounts.map(\.id)
        XCTAssertEqual(initialIDs.first, ClaudeCodeAccount.defaultID)

        store.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let reorderedIDs = store.accounts.map(\.id)
        XCTAssertEqual(reorderedIDs, [initialIDs[1], initialIDs[2], initialIDs[0]])

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accounts.map(\.id), reorderedIDs)
    }

    func testRemovingCustomProfilePrunesStoredAccountOrder() {
        let store = ClaudeCodeAccountStore(userDefaults: defaults)
        store.addAccount(name: "shipshitdev", configDirectory: "/tmp/shipshitdev")
        store.addAccount(name: "genfeedai", configDirectory: "/tmp/genfeedai")

        let initialIDs = store.accounts.map(\.id)
        store.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        store.removeAccount(id: initialIDs[1])

        XCTAssertFalse(store.accounts.map(\.id).contains(initialIDs[1]))

        let reloaded = ClaudeCodeAccountStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.accounts.map(\.id).contains(initialIDs[1]))
        XCTAssertEqual(reloaded.accounts.map(\.id), [initialIDs[2], initialIDs[0]])
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
