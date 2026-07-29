import XCTest
@testable import MeterBar

final class GrokAccountStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "GrokAccountStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultProfileNeedsNoConfigurationAndUsesOfficialHomeResolution() {
        let store = GrokAccountStore(userDefaults: defaults)

        XCTAssertEqual(store.accounts, [.defaultAccount])
        XCTAssertNil(store.accounts.first?.homeDirectory)
        XCTAssertEqual(
            GrokHomeDirectory.path(
                environment: [:],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.grok"
        )
        XCTAssertEqual(
            GrokHomeDirectory.path(
                environment: ["GROK_HOME": "~/.grok-work"],
                realHomeDirectory: "/Users/tester"
            ),
            "/Users/tester/.grok-work"
        )
        XCTAssertEqual(
            GrokHomeDirectory.authFilePath(
                environment: ["GROK_HOME": "/Volumes/profiles/grok"],
                realHomeDirectory: "/Users/tester"
            ),
            "/Volumes/profiles/grok/auth.json"
        )
    }

    func testProfilesPersistRenameEnableRemoveAndOrder() throws {
        let store = GrokAccountStore(userDefaults: defaults)
        store.addAccount(name: "Work", homeDirectory: "/tmp/grok-work")
        store.addAccount(name: "Personal", homeDirectory: "/tmp/grok-personal")
        let work = try XCTUnwrap(store.customAccounts.first { $0.name == "Work" })
        let personal = try XCTUnwrap(store.customAccounts.first { $0.name == "Personal" })

        store.updateAccount(id: work.id, name: "Team", homeDirectory: "/tmp/grok-team")
        store.setEnabled(false, for: personal.id)
        store.moveAccounts(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        var reloaded = GrokAccountStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accounts.map(\.name), ["Personal", GrokAccount.defaultName, "Team"])
        XCTAssertEqual(reloaded.accounts.first(where: { $0.id == work.id })?.homeDirectory, "/tmp/grok-team")
        XCTAssertFalse(try XCTUnwrap(reloaded.accounts.first { $0.id == personal.id }).isEnabled)

        reloaded.removeAccount(id: work.id)
        reloaded = GrokAccountStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.accounts.contains { $0.id == work.id })
        XCTAssertTrue(reloaded.accounts.contains { $0.id == GrokAccount.defaultID })
    }

    func testLegacyProfileWithoutEnabledFlagMigratesAsEnabled() {
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"Legacy","homeDirectory":"/tmp/grok-legacy"}]"#
        defaults.set(Data(legacy.utf8), forKey: StorageKeys.grokCustomAccounts)

        let store = GrokAccountStore(userDefaults: defaults)

        XCTAssertEqual(store.customAccounts.count, 1)
        XCTAssertTrue(store.customAccounts[0].isEnabled)
    }
}
