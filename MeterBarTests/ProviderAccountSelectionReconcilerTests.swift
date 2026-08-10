import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Downstream reconciliation after a Codex enable/disable/delete (issue #304).
///
/// The Settings view used to compute this inline in a `private func` on the
/// `View`, so the behavior that matters most — which menu-bar keys, widget
/// identifiers, and Session Wake accounts survive the mutation — had no test.
/// The projection is a value type here, and the applier is exercised against
/// real stores backed by throwaway `UserDefaults` suites.
final class ProviderAccountSelectionReconcilerTests: XCTestCase {
    // MARK: Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ProviderAccountSelectionReconcilerTests.\(UUID().uuidString)"
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

    // MARK: - Availability projection

    func testDisabledCodexProfileDropsOutOfEveryAvailableIdentitySet() {
        let availability = makeAvailability(codexCustomEnabled: false)

        XCTAssertFalse(availability.menuBarKeys.contains(codexCustomKey))
        XCTAssertFalse(availability.widgetAccountIdentifiers.contains(codexCustomWidgetID))
        XCTAssertFalse(availability.enabledCodexAccountIDs.contains(codexCustomID))

        XCTAssertTrue(availability.menuBarKeys.contains(codexDefaultKey))
        XCTAssertTrue(availability.enabledCodexAccountIDs.contains(CodexAccount.defaultID))
    }

    func testUntrackedCodexProviderDropsEveryCodexProfile() {
        let availability = makeAvailability(enabledServices: [.claudeCode, .grok])

        XCTAssertFalse(availability.menuBarKeys.contains(codexDefaultKey))
        XCTAssertFalse(availability.menuBarKeys.contains(codexCustomKey))
        XCTAssertTrue(availability.enabledCodexAccountIDs.isEmpty)
    }

    /// Regression: the projection previously omitted Grok accounts entirely, so
    /// reconciling after a *Codex* change pruned every selected Grok status item
    /// and widget account as collateral damage.
    func testCodexReconciliationPreservesGrokAndClaudeIdentities() {
        let availability = makeAvailability(codexCustomEnabled: false)

        XCTAssertTrue(availability.menuBarKeys.contains(grokDefaultKey))
        XCTAssertTrue(availability.menuBarKeys.contains(claudeDefaultKey))
        XCTAssertTrue(availability.widgetAccountIdentifiers.contains(grokDefaultWidgetID))
        XCTAssertTrue(availability.widgetAccountIdentifiers.contains(claudeDefaultWidgetID))
    }

    // MARK: - Applying to downstream consumers

    func testApplyPrunesMenuBarSelectionAndMergedKeyForDisabledProfile() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        menuBarSelection.select(codexCustomKey)
        menuBarSelection.select(grokDefaultKey)
        menuBarSelection.setMergedAccountKey(codexCustomKey)

        apply(makeAvailability(codexCustomEnabled: false), menuBarSelection: menuBarSelection)

        XCTAssertEqual(menuBarSelection.selectedAccountKeys, [grokDefaultKey])
        XCTAssertNil(menuBarSelection.mergedAccountKey)
    }

    func testApplyPrunesExplicitWidgetSelectionForDisabledProfile() throws {
        let widgetPreferences = WidgetPreferencesStore(
            userDefaults: try XCTUnwrap(defaults),
            reloadTimelines: {}
        )
        widgetPreferences.setSelectedAccounts([codexCustomWidgetID, grokDefaultWidgetID])

        apply(makeAvailability(codexCustomEnabled: false), widgetPreferences: widgetPreferences)

        XCTAssertEqual(
            widgetPreferences.preferences.accountSelection.explicitIdentifiers,
            [grokDefaultWidgetID]
        )
    }

    func testApplyClearsAndDisarmsSessionWakeWhenItsCodexAccountIsDisabled() throws {
        let sessionWake = SessionWakeSettingsStore(userDefaults: try XCTUnwrap(defaults))
        sessionWake.setWakeProvider(.codex)
        sessionWake.setWakeCodexAccountID(codexCustomID)
        sessionWake.acknowledgeFirstRunAndTurnOn()
        XCTAssertTrue(sessionWake.isOn)

        apply(makeAvailability(codexCustomEnabled: false), sessionWakeSettings: sessionWake)

        XCTAssertNil(sessionWake.wakeCodexAccountID)
        XCTAssertFalse(sessionWake.isOn)
    }

    func testApplyLeavesSessionWakeAloneWhenItsCodexAccountSurvives() throws {
        let sessionWake = SessionWakeSettingsStore(userDefaults: try XCTUnwrap(defaults))
        sessionWake.setWakeProvider(.codex)
        sessionWake.setWakeCodexAccountID(codexCustomID)

        apply(makeAvailability(codexCustomEnabled: true), sessionWakeSettings: sessionWake)

        XCTAssertEqual(sessionWake.wakeCodexAccountID, codexCustomID)
    }

    // MARK: - Claude and Grok parity (issue #410)

    /// The Codex handlers reconciled on every enable/disable/delete; Claude's and
    /// Grok's did not, so a disabled Claude profile kept its status-item slot:
    /// `MenuBarAccountItemPlanner` drops the vanished key while `select()` still
    /// counts it against `itemLimit`, and the slot cannot be reused until the
    /// user reselects by hand or relaunches.
    func testApplyPrunesDisabledClaudeSelectionAndFreesItsStatusItemSlot() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        try fillEverySlot(of: menuBarSelection, lastKey: claudeCustomKey)

        apply(makeAvailability(claudeCustomEnabled: false), menuBarSelection: menuBarSelection)

        XCTAssertFalse(menuBarSelection.selectedAccountKeys.contains(claudeCustomKey))
        XCTAssertEqual(menuBarSelection.select(grokDefaultKey), .updated)
    }

    func testApplyPrunesDisabledGrokSelectionAndFreesItsStatusItemSlot() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        try fillEverySlot(of: menuBarSelection, lastKey: grokCustomKey)

        apply(makeAvailability(grokCustomEnabled: false), menuBarSelection: menuBarSelection)

        XCTAssertFalse(menuBarSelection.selectedAccountKeys.contains(grokCustomKey))
        XCTAssertEqual(menuBarSelection.select(grokDefaultKey), .updated)
    }

    /// Deleting an account removes it from the store, so the same pass that
    /// handles a disable also has to clear the switcher binding — otherwise the
    /// merged status item stays pointed at an account that no longer exists.
    func testApplyPrunesDeletedClaudeAccountFromSelectionAndMergedKey() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        menuBarSelection.select(claudeCustomKey)
        menuBarSelection.select(grokDefaultKey)
        menuBarSelection.setMergedAccountKey(claudeCustomKey)

        apply(makeAvailability(claudeAccountsIncludeCustom: false), menuBarSelection: menuBarSelection)

        XCTAssertEqual(menuBarSelection.selectedAccountKeys, [grokDefaultKey])
        XCTAssertNil(menuBarSelection.mergedAccountKey)
    }

    func testApplyPrunesDeletedGrokAccountFromSelectionAndMergedKey() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        menuBarSelection.select(grokCustomKey)
        menuBarSelection.select(claudeDefaultKey)
        menuBarSelection.setMergedAccountKey(grokCustomKey)

        apply(makeAvailability(grokAccountsIncludeCustom: false), menuBarSelection: menuBarSelection)

        XCTAssertEqual(menuBarSelection.selectedAccountKeys, [claudeDefaultKey])
        XCTAssertNil(menuBarSelection.mergedAccountKey)
    }

    /// Untracking a whole provider leaks exactly like disabling one of its
    /// accounts: `providerEnabledBinding` used to reconcile for Codex only.
    func testApplyPrunesEveryProfileOfAnUntrackedProvider() throws {
        let menuBarSelection = MenuBarAccountSelectionStore(userDefaults: try XCTUnwrap(defaults))
        menuBarSelection.select(claudeDefaultKey)
        menuBarSelection.select(claudeCustomKey)
        menuBarSelection.select(grokDefaultKey)

        apply(
            makeAvailability(enabledServices: [.codexCli, .grok]),
            menuBarSelection: menuBarSelection
        )

        XCTAssertEqual(menuBarSelection.selectedAccountKeys, [grokDefaultKey])
    }

    func testApplyPrunesExplicitWidgetSelectionForDisabledClaudeProfile() throws {
        let widgetPreferences = WidgetPreferencesStore(
            userDefaults: try XCTUnwrap(defaults),
            reloadTimelines: {}
        )
        widgetPreferences.setSelectedAccounts([claudeCustomWidgetID, grokDefaultWidgetID])

        apply(makeAvailability(claudeCustomEnabled: false), widgetPreferences: widgetPreferences)

        XCTAssertEqual(
            widgetPreferences.preferences.accountSelection.explicitIdentifiers,
            [grokDefaultWidgetID]
        )
    }

    /// Session Wake keeps Claude and Codex on separate reconcile paths
    /// (`reconcileAccounts` vs `reconcileCodexAccounts`); the shared reconciler
    /// owns only the Codex one, so a Claude wake target must survive it.
    func testApplyLeavesClaudeSessionWakeTargetToItsOwnReconcilePath() throws {
        let sessionWake = SessionWakeSettingsStore(userDefaults: try XCTUnwrap(defaults))
        sessionWake.setWakeAccountID(claudeCustomID)

        apply(makeAvailability(claudeCustomEnabled: false), sessionWakeSettings: sessionWake)

        XCTAssertEqual(sessionWake.wakeAccountID, claudeCustomID)
    }

    // MARK: Private

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let codexCustomID = UUID()
    private let claudeCustomID = UUID()
    private let grokCustomID = UUID()

    private var codexDefaultKey: String {
        MenuBarAccountKey.make(service: .codexCli, accountID: CodexAccount.defaultID)
    }

    private var codexCustomKey: String {
        MenuBarAccountKey.make(service: .codexCli, accountID: codexCustomID)
    }

    private var grokDefaultKey: String {
        MenuBarAccountKey.make(service: .grok, accountID: GrokAccount.defaultID)
    }

    private var claudeDefaultKey: String {
        MenuBarAccountKey.make(service: .claudeCode, accountID: ClaudeCodeAccount.defaultID)
    }

    private var claudeCustomKey: String {
        MenuBarAccountKey.make(service: .claudeCode, accountID: claudeCustomID)
    }

    private var grokCustomKey: String {
        MenuBarAccountKey.make(service: .grok, accountID: grokCustomID)
    }

    private var codexCustomWidgetID: WidgetAccountIdentifier {
        .account(service: .codexCli, id: codexCustomID)
    }

    private var grokDefaultWidgetID: WidgetAccountIdentifier {
        .account(service: .grok, id: GrokAccount.defaultID)
    }

    private var claudeDefaultWidgetID: WidgetAccountIdentifier {
        .account(service: .claudeCode, id: ClaudeCodeAccount.defaultID)
    }

    private var claudeCustomWidgetID: WidgetAccountIdentifier {
        .account(service: .claudeCode, id: claudeCustomID)
    }

    /// Occupies every status-item slot, ending on `lastKey`, so a test can prove
    /// the cap actually blocks a further selection before reconciliation runs.
    ///
    /// The filler keys all stay available across the reconcile under test, so the
    /// freed slot can only have come from `lastKey` being pruned — not from the
    /// filler evaporating too.
    private func fillEverySlot(
        of store: MenuBarAccountSelectionStore,
        lastKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let filler = [claudeDefaultKey, codexDefaultKey, codexCustomKey]
        XCTAssertEqual(
            filler.count + 1,
            store.itemLimit,
            "filler no longer fills the cap exactly; the reuse assertion would be vacuous",
            file: file,
            line: line
        )
        for key in filler + [lastKey] {
            XCTAssertEqual(store.select(key), .updated, file: file, line: line)
        }
        XCTAssertEqual(
            store.select(grokDefaultKey),
            .rejectedLimit(store.itemLimit),
            "the cap must be reached before reconciliation frees a slot",
            file: file,
            line: line
        )
    }

    private func makeAvailability(
        codexCustomEnabled: Bool = true,
        claudeCustomEnabled: Bool = true,
        grokCustomEnabled: Bool = true,
        claudeAccountsIncludeCustom: Bool = true,
        grokAccountsIncludeCustom: Bool = true,
        enabledServices: Set<ServiceType> = [.claudeCode, .codexCli, .grok]
    ) -> ProviderAccountSelectionAvailability {
        ProviderAccountSelectionAvailability(
            claudeAccounts: [.defaultAccount] + (claudeAccountsIncludeCustom ? [
                ClaudeCodeAccount(
                    id: claudeCustomID,
                    name: "Work",
                    configDirectory: "/tmp/claude-work",
                    isEnabled: claudeCustomEnabled
                )
            ] : []),
            codexAccounts: [
                .defaultAccount,
                CodexAccount(
                    id: codexCustomID,
                    name: "Work",
                    homeDirectory: "/tmp/codex-work",
                    isEnabled: codexCustomEnabled
                )
            ],
            grokAccounts: [.defaultAccount] + (grokAccountsIncludeCustom ? [
                GrokAccount(
                    id: grokCustomID,
                    name: "Work",
                    homeDirectory: "/tmp/grok-work",
                    isEnabled: grokCustomEnabled
                )
            ] : []),
            enabledServices: enabledServices
        )
    }

    private func apply(
        _ availability: ProviderAccountSelectionAvailability,
        menuBarSelection: MenuBarAccountSelectionStore? = nil,
        widgetPreferences: WidgetPreferencesStore? = nil,
        sessionWakeSettings: SessionWakeSettingsStore? = nil
    ) {
        let defaults = defaults ?? .standard
        ProviderAccountSelectionReconciler.apply(
            availability,
            menuBarSelection: menuBarSelection ?? MenuBarAccountSelectionStore(userDefaults: defaults),
            widgetPreferences: widgetPreferences ?? WidgetPreferencesStore(
                userDefaults: defaults,
                reloadTimelines: {}
            ),
            sessionWakeSettings: sessionWakeSettings ?? SessionWakeSettingsStore(userDefaults: defaults)
        )
    }
}
