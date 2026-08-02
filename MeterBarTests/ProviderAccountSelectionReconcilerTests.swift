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

    // MARK: Private

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let codexCustomID = UUID()

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

    private var codexCustomWidgetID: WidgetAccountIdentifier {
        .account(service: .codexCli, id: codexCustomID)
    }

    private var grokDefaultWidgetID: WidgetAccountIdentifier {
        .account(service: .grok, id: GrokAccount.defaultID)
    }

    private var claudeDefaultWidgetID: WidgetAccountIdentifier {
        .account(service: .claudeCode, id: ClaudeCodeAccount.defaultID)
    }

    private func makeAvailability(
        codexCustomEnabled: Bool = true,
        enabledServices: Set<ServiceType> = [.claudeCode, .codexCli, .grok]
    ) -> ProviderAccountSelectionAvailability {
        ProviderAccountSelectionAvailability(
            claudeAccounts: [.defaultAccount],
            codexAccounts: [
                .defaultAccount,
                CodexAccount(
                    id: codexCustomID,
                    name: "Work",
                    homeDirectory: "/tmp/codex-work",
                    isEnabled: codexCustomEnabled
                )
            ],
            grokAccounts: [.defaultAccount],
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
