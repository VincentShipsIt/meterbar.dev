import Foundation
import XCTest
@testable import MeterBar

final class AccountFailoverSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "AccountFailoverSettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testBothProvidersDefaultOffAndPreferredAccountIsFirstEnabledProfile() {
        let store = AccountFailoverSettingsStore(userDefaults: defaults)
        let claude = [UUID(), UUID()]
        let codex = [UUID(), UUID()]

        XCTAssertFalse(store.isEnabled(for: .claudeCode))
        XCTAssertFalse(store.isEnabled(for: .codexCli))
        XCTAssertEqual(store.activeAccountID(for: .claudeCode, orderedAccountIDs: claude), claude.first)
        XCTAssertEqual(store.activeAccountID(for: .codexCli, orderedAccountIDs: codex), codex.first)
    }

    func testEnablementAndLiveAccountPersistIndependentlyPerProvider() {
        let claude = UUID()
        let codex = UUID()
        let store = AccountFailoverSettingsStore(userDefaults: defaults)

        store.setEnabled(true, for: .claudeCode)
        store.setActiveAccountID(claude, for: .claudeCode)
        store.setActiveAccountID(codex, for: .codexCli)

        let reloaded = AccountFailoverSettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.isEnabled(for: .claudeCode))
        XCTAssertFalse(reloaded.isEnabled(for: .codexCli))
        XCTAssertEqual(reloaded.activeAccountID(for: .claudeCode, orderedAccountIDs: [claude, UUID()]), claude)
        XCTAssertEqual(reloaded.activeAccountID(for: .codexCli, orderedAccountIDs: [codex, UUID()]), codex)
    }

    func testRemovedLiveAccountReconcilesToPreferred() {
        let preferred = UUID()
        let removed = UUID()
        let store = AccountFailoverSettingsStore(userDefaults: defaults)
        store.setActiveAccountID(removed, for: .claudeCode)

        store.reconcileAccounts([preferred], for: .claudeCode)

        XCTAssertEqual(store.activeAccountID(for: .claudeCode, orderedAccountIDs: [preferred]), preferred)
    }
}
