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
        let grok = GrokAccount(id: UUID(), name: "Build", homeDirectory: "/tmp/grok-build")

        let identities = MenuBarAccountCatalog.identities(
            claudeAccounts: [claude],
            codexAccounts: [codex],
            grokAccounts: [grok],
            enabledServices: [.claudeCode, .codexCli, .grok]
        )

        XCTAssertEqual(identities.map(\.key), [
            "\(ServiceType.claudeCode.rawValue):\(claude.id.uuidString)",
            "\(ServiceType.codexCli.rawValue):\(codex.id.uuidString)",
            "\(ServiceType.grok.rawValue):\(grok.id.uuidString)"
        ])
        XCTAssertEqual(identities.map(\.displayName), ["Work", "Personal", "Build"])
        XCTAssertEqual(identities.map(\.badge), ["W", "P", "B"])
        XCTAssertEqual(identities.map(\.isEnabled), [true, true, true])
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
            grokAccounts: [],
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
            claudeAccounts: [account],
            codexAccounts: [],
            grokAccounts: [],
            enabledServices: [.claudeCode]
        ).first

        XCTAssertEqual(identity?.displayName, ".claude-team")
        XCTAssertEqual(identity?.badge, "C")
    }

    // MARK: - Selection store

    /// An installation that has never opted in keeps exactly one status item.
    func testDefaultsPreserveTheLegacySingleStatusItem() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))

        XCTAssertTrue(store.selectedAccountKeys.isEmpty)
        XCTAssertNil(store.mergedAccountKey)
    }

    func testSelectionPersistsAcrossRelaunch() throws {
        let defaults = try XCTUnwrap(defaults)
        let store = MenuBarAccountSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.select("claudeCode:a"), .updated)
        XCTAssertEqual(store.select("codexCli:b"), .updated)
        store.setMergedAccountKey("codexCli:b")

        let relaunched = MenuBarAccountSelectionStore(userDefaults: defaults)

        XCTAssertEqual(relaunched.selectedAccountKeys, ["claudeCode:a", "codexCli:b"])
        XCTAssertEqual(relaunched.mergedAccountKey, "codexCli:b")
    }

    func testSelectionRejectsAdditionsBeyondTheDocumentedCap() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        let limit = MenuBarAccountItemPlanner.maximumConcurrentItems

        for index in 0 ..< limit {
            XCTAssertEqual(store.select("claudeCode:\(index)"), .updated)
        }

        XCTAssertEqual(store.select("claudeCode:overflow"), .rejectedLimit(limit))
        XCTAssertEqual(store.selectedAccountKeys.count, limit)
        XCTAssertFalse(store.selectedAccountKeys.contains("claudeCode:overflow"))
    }

    func testReselectingAKeyAtTheCapIsUnchangedRatherThanRejected() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        for index in 0 ..< MenuBarAccountItemPlanner.maximumConcurrentItems {
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
        let overCap = (0 ... MenuBarAccountItemPlanner.maximumConcurrentItems).map { "claudeCode:\($0)" }
        defaults.set(overCap + ["claudeCode:0", "  "], forKey: StorageKeys.menuBarSelectedAccountKeys)

        let store = MenuBarAccountSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedAccountKeys.count, MenuBarAccountItemPlanner.maximumConcurrentItems)
        XCTAssertEqual(Set(store.selectedAccountKeys).count, store.selectedAccountKeys.count)
    }

    /// Removing an account in Settings must drop it from both preferences.
    /// A leftover key is invisible — the planner skips accounts it cannot find,
    /// so the item never appears while still consuming one of the four slots.
    func testForgetClearsBothTheSelectionAndTheSwitcherBinding() throws {
        let defaults = try XCTUnwrap(defaults)
        let store = MenuBarAccountSelectionStore(userDefaults: defaults)
        store.select("claudeCode:a")
        store.select("codexCli:b")
        store.setMergedAccountKey("claudeCode:a")

        store.forget("claudeCode:a")

        XCTAssertEqual(store.selectedAccountKeys, ["codexCli:b"])
        XCTAssertNil(store.mergedAccountKey)
        XCTAssertNil(defaults.string(forKey: StorageKeys.menuBarMergedAccountKey))
        XCTAssertEqual(defaults.stringArray(forKey: StorageKeys.menuBarSelectedAccountKeys), ["codexCli:b"])
    }

    func testForgetLeavesUnrelatedAccountsAlone() throws {
        let store = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        store.select("claudeCode:a")
        store.setMergedAccountKey("claudeCode:a")

        store.forget("codexCli:gone")

        XCTAssertEqual(store.selectedAccountKeys, ["claudeCode:a"])
        XCTAssertEqual(store.mergedAccountKey, "claudeCode:a")
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
