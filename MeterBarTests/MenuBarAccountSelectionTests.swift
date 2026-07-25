import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Per-account menu-bar status items (issue #266) — the account catalog and the
/// persisted selection.
///
/// Account names are user-supplied, so `MenuBarAccountLabel` is the single
/// sanitizing seam every rendered label goes through: it collapses control
/// characters, caps the length, and reduces a path-like name to its last
/// component so a configured `CLAUDE_CONFIG_DIR` can never reach the menu bar.
final class MenuBarAccountSelectionTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarAccountSelectionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: - Label sanitizing

    func testDisplayNameCollapsesWhitespaceAndControlCharacters() {
        XCTAssertEqual(MenuBarAccountLabel.displayName(for: "  Work\n\tProfile  "), "Work Profile")
    }

    func testDisplayNameTruncatesLongLabels() {
        let result = MenuBarAccountLabel.displayName(for: String(repeating: "A", count: 80))

        XCTAssertEqual(result.count, MenuBarAccountLabel.maximumLength)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    /// A label is the only account-derived string that reaches the menu bar, so
    /// a name that is (or contains) a config-directory path must be reduced to
    /// its last component — never the full path.
    func testDisplayNameNeverLeaksAConfigDirectoryPath() {
        let result = MenuBarAccountLabel.displayName(for: "/Users/vincent/.claude-work/")

        XCTAssertEqual(result, ".claude-work")
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains("Users"))
        XCTAssertFalse(result.contains("vincent"))
    }

    func testDisplayNameFallsBackWhenNameIsBlank() {
        XCTAssertEqual(MenuBarAccountLabel.displayName(for: "   \n "), MenuBarAccountLabel.fallbackName)
    }

    func testBadgeDerivesShortInitials() {
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "Work Profile"), "WP")
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "default"), "D")
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "Default CLI Profile"), "DC")
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "/Users/vincent/.claude-work"), "C")
    }

    func testBadgeFallsBackWhenNoAlphanumericsExist() {
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "🙂"), MenuBarAccountLabel.fallbackBadge)
        XCTAssertEqual(MenuBarAccountLabel.badge(for: "   "), "A") // "Account" fallback name
    }

    // MARK: - Account catalog

    func testCatalogBuildsStableKeysAcrossProviders() {
        let claude = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let codex = CodexAccount(id: UUID(), name: "Personal", homeDirectory: "/tmp/personal")

        let identities = MenuBarAccountCatalog.identities(
            claudeAccounts: [claude],
            codexAccounts: [codex],
            enabledServices: [.claudeCode, .codexCli]
        )

        XCTAssertEqual(identities.map(\.key), [
            "\(ServiceType.claudeCode.rawValue):\(claude.id.uuidString)",
            "\(ServiceType.codexCli.rawValue):\(codex.id.uuidString)"
        ])
        XCTAssertEqual(identities.map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(identities.map(\.badge), ["W", "P"])
        XCTAssertEqual(identities.map(\.isEnabled), [true, true])
    }

    /// A disabled account and an account whose provider is untracked are both
    /// ineligible for a status item; the catalog folds both into `isEnabled`.
    func testCatalogFoldsAccountAndProviderDisabledStates() {
        let disabledAccount = ClaudeCodeAccount(
            id: UUID(), name: "Off", configDirectory: nil, isEnabled: false
        )
        let enabledAccount = ClaudeCodeAccount(id: UUID(), name: "On", configDirectory: nil)
        let codex = CodexAccount(id: UUID(), name: "Codex", homeDirectory: nil)

        let identities = MenuBarAccountCatalog.identities(
            claudeAccounts: [disabledAccount, enabledAccount],
            codexAccounts: [codex],
            enabledServices: [.claudeCode]
        )

        XCTAssertEqual(identities.map(\.isEnabled), [false, true, false])
    }

    /// The catalog sanitizes at construction, so no downstream renderer can
    /// accidentally use a raw account name.
    func testCatalogSanitizesUserSuppliedNames() {
        let account = ClaudeCodeAccount(
            id: UUID(),
            name: "/Users/vincent/Library/Application Support/.claude-team",
            configDirectory: "/Users/vincent/Library/Application Support/.claude-team"
        )

        let identity = MenuBarAccountCatalog.identities(
            claudeAccounts: [account], codexAccounts: [], enabledServices: [.claudeCode]
        ).first

        XCTAssertEqual(identity?.displayName, ".claude-team")
        XCTAssertEqual(identity?.badge, "C")
    }

    // MARK: - Selection store

    /// An installation that has never opted in keeps exactly one status item.
    func testDefaultsPreserveTheLegacySingleStatusItem() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))

        XCTAssertEqual(store.mode, .single)
        XCTAssertTrue(store.selectedAccountKeys.isEmpty)
        XCTAssertNil(store.mergedAccountKey)
    }

    func testSelectionPersistsAcrossRelaunch() throws {
        let defaults = try XCTUnwrap(defaults)
        let store = MenuBarAccountSelectionStore(userDefaults: defaults)

        store.setMode(.perAccount)
        XCTAssertEqual(store.select("claudeCode:a"), .updated)
        XCTAssertEqual(store.select("codexCli:b"), .updated)
        store.setMergedAccountKey("codexCli:b")

        let relaunched = MenuBarAccountSelectionStore(userDefaults: defaults)

        XCTAssertEqual(relaunched.mode, .perAccount)
        XCTAssertEqual(relaunched.selectedAccountKeys, ["claudeCode:a", "codexCli:b"])
        XCTAssertEqual(relaunched.mergedAccountKey, "codexCli:b")
    }

    func testSelectionRejectsAdditionsBeyondTheDocumentedCap() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        let limit = MenuBarStatusItemPlanner.maximumConcurrentItems

        for index in 0 ..< limit {
            XCTAssertEqual(store.select("claudeCode:\(index)"), .updated)
        }

        XCTAssertEqual(store.select("claudeCode:overflow"), .rejectedLimit(limit))
        XCTAssertEqual(store.selectedAccountKeys.count, limit)
        XCTAssertFalse(store.selectedAccountKeys.contains("claudeCode:overflow"))
    }

    func testReselectingAKeyAtTheCapIsUnchangedRatherThanRejected() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        for index in 0 ..< MenuBarStatusItemPlanner.maximumConcurrentItems {
            store.select("claudeCode:\(index)")
        }

        XCTAssertEqual(store.select("claudeCode:0"), .unchanged)
    }

    func testDeselectingRemovesOnlyThatKeyAndKeepsOrder() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        store.select("a")
        store.select("b")
        store.select("c")

        XCTAssertEqual(store.deselect("b"), .updated)
        XCTAssertEqual(store.selectedAccountKeys, ["a", "c"])
        XCTAssertEqual(store.deselect("b"), .unchanged)
    }

    func testSetSelectedRoutesBothDirections() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))

        XCTAssertEqual(store.setSelected(true, for: "a"), .updated)
        XCTAssertTrue(store.isSelected("a"))
        XCTAssertEqual(store.setSelected(false, for: "a"), .updated)
        XCTAssertFalse(store.isSelected("a"))
    }

    /// Defaults written by a future build (or hand-edited) must not exceed the
    /// cap or install duplicate items on load.
    func testLoadNormalizesDuplicateAndOverCapPersistedSelections() throws {
        let defaults = try XCTUnwrap(defaults)
        let overCap = (0 ... MenuBarStatusItemPlanner.maximumConcurrentItems).map { "claudeCode:\($0)" }
        defaults.set(overCap + ["claudeCode:0", "  "], forKey: StorageKeys.menuBarSelectedAccountKeys)

        let store = MenuBarAccountSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedAccountKeys.count, MenuBarStatusItemPlanner.maximumConcurrentItems)
        XCTAssertEqual(Set(store.selectedAccountKeys).count, store.selectedAccountKeys.count)
    }

    func testBlankMergedKeyClearsThePreference() throws {
        let defaults = try XCTUnwrap(defaults)
        let store = MenuBarAccountSelectionStore(userDefaults: defaults)

        store.setMergedAccountKey("claudeCode:a")
        store.setMergedAccountKey("   ")

        XCTAssertNil(store.mergedAccountKey)
        XCTAssertNil(defaults.string(forKey: StorageKeys.menuBarMergedAccountKey))
    }

    // MARK: Private

    private var suiteName: String!
    private var defaults: UserDefaults!
}
