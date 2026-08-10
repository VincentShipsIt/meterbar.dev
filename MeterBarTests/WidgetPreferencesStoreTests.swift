import Foundation
import XCTest
@testable import MeterBarShared

final class WidgetPreferencesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WidgetPreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsPreserveExistingWidgetBehavior() {
        let store = makeStore()

        XCTAssertEqual(store.preferences.accountSelection, .all)
        XCTAssertEqual(store.preferences.displayMode, .used)
        XCTAssertEqual(store.preferences.visibleQuotaWindows, [.weekly])
        XCTAssertFalse(store.preferences.showsResetTime)
        XCTAssertFalse(store.preferences.showsFreshness)
        XCTAssertEqual(store.preferences.accountOrdering, .provider)
        XCTAssertTrue(store.preferences.preservesLegacyOpenRouterBalance)
    }

    func testPreferencesPersistAcrossRelaunch() {
        let claude = WidgetAccountIdentifier.account(service: .claudeCode, id: UUID())
        let codex = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        let store = makeStore()

        store.setSelectedAccounts([claude, codex])
        store.setDisplayMode(.remaining)
        store.setVisibleQuotaWindows([.session, .weekly, .codeReview])
        store.setShowsResetTime(true)
        store.setShowsFreshness(true)
        store.setAccountOrdering(.urgency)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.preferences.accountSelection.explicitIdentifiers, [claude, codex])
        XCTAssertEqual(reloaded.preferences.displayMode, .remaining)
        XCTAssertEqual(reloaded.preferences.visibleQuotaWindows, [.session, .weekly, .codeReview])
        XCTAssertTrue(reloaded.preferences.showsResetTime)
        XCTAssertTrue(reloaded.preferences.showsFreshness)
        XCTAssertEqual(reloaded.preferences.accountOrdering, .urgency)
        XCTAssertFalse(reloaded.preferences.preservesLegacyOpenRouterBalance)
    }

    func testSelectAllAutomaticallyIncludesNewEnabledAccounts() {
        let claude = candidate(service: .claudeCode, accountOrder: 0)
        let codex = candidate(service: .codexCli, accountOrder: 0)
        let preferences = WidgetPreferences.defaults

        XCTAssertEqual(
            WidgetAccountSelector.select(from: [claude], using: preferences).map(\.identifier),
            [claude.identifier]
        )
        XCTAssertEqual(
            WidgetAccountSelector.select(from: [claude, codex], using: preferences).map(\.identifier),
            [claude.identifier, codex.identifier]
        )
        XCTAssertEqual(preferences.accountSelection, .all)
    }

    func testExplicitSelectionIgnoresUnselectedDisabledUnavailableAndRemovedAccounts() {
        let selected = candidate(service: .claudeCode, accountOrder: 0)
        let unselected = candidate(service: .codexCli, accountOrder: 0)
        let disabledProvider = candidate(
            service: .cursor,
            accountOrder: 0,
            isProviderEnabled: false
        )
        let disabledAccount = candidate(
            service: .claudeCode,
            accountOrder: 1,
            isAccountEnabled: false
        )
        let unavailable = candidate(
            service: .codexCli,
            accountOrder: 1,
            isAvailable: false
        )
        var preferences = WidgetPreferences.defaults
        preferences.accountSelection = .explicit([
            selected.identifier,
            disabledProvider.identifier,
            disabledAccount.identifier,
            unavailable.identifier,
            WidgetAccountIdentifier(rawValue: "account:removed")
        ])

        let result = WidgetAccountSelector.select(
            from: [unselected, unavailable, disabledAccount, selected, disabledProvider],
            using: preferences
        )

        XCTAssertEqual(result.map(\.identifier), [selected.identifier])
    }

    func testProviderAndUrgencyOrderingAreDeterministic() {
        let claudeSecond = candidate(service: .claudeCode, accountOrder: 1, urgency: 90)
        let claudeFirst = candidate(service: .claudeCode, accountOrder: 0, urgency: 20)
        let codex = candidate(service: .codexCli, accountOrder: 0, urgency: 80)
        var preferences = WidgetPreferences.defaults

        let providerOrdered = WidgetAccountSelector.select(
            from: [codex, claudeSecond, claudeFirst],
            using: preferences
        )
        XCTAssertEqual(
            providerOrdered.map(\.identifier),
            [claudeFirst.identifier, claudeSecond.identifier, codex.identifier]
        )

        preferences.accountOrdering = .urgency

        let urgencyOrdered = WidgetAccountSelector.select(
            from: [codex, claudeSecond, claudeFirst],
            using: preferences
        )
        XCTAssertEqual(
            urgencyOrdered.map(\.identifier),
            [claudeSecond.identifier, codex.identifier, claudeFirst.identifier]
        )
    }

    func testEveryChangedPreferenceRequestsOneTimelineReload() {
        var reloadCount = 0
        let store = WidgetPreferencesStore(userDefaults: defaults) {
            reloadCount += 1
        }
        let account = WidgetAccountIdentifier.provider(.claudeCode)

        store.setSelectedAccounts([account])
        store.selectAllAccounts()
        store.setDisplayMode(.remaining)
        store.setVisibleQuotaWindows([.session])
        store.setShowsResetTime(true)
        store.setShowsFreshness(true)
        store.setAccountOrdering(.urgency)

        XCTAssertEqual(reloadCount, 7)

        store.setAccountOrdering(.urgency)

        XCTAssertEqual(reloadCount, 7)
    }

    func testChoosingUsedModeDisablesLegacyOpenRouterBalanceAndReloads() {
        var reloadCount = 0
        let store = WidgetPreferencesStore(userDefaults: defaults) {
            reloadCount += 1
        }

        store.setDisplayMode(.used)

        XCTAssertEqual(store.preferences.displayMode, .used)
        XCTAssertFalse(store.preferences.preservesLegacyOpenRouterBalance)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertFalse(makeStore().preferences.preservesLegacyOpenRouterBalance)
    }

    func testReconcileAvailableAccountsPrunesExplicitDisabledSelection() {
        var reloadCount = 0
        let store = WidgetPreferencesStore(userDefaults: defaults) {
            reloadCount += 1
        }
        let enabled = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        let disabled = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        store.setSelectedAccounts([enabled, disabled])

        store.reconcileAvailableAccounts([enabled])

        XCTAssertEqual(store.preferences.accountSelection.explicitIdentifiers, [enabled])
        XCTAssertEqual(reloadCount, 2)
    }

    func testReconcileAvailableAccountsLeavesDynamicAllSelectionUntouched() {
        let store = makeStore()

        store.reconcileAvailableAccounts([])

        XCTAssertEqual(store.preferences.accountSelection, .all)
    }

    func testStableIdentifiersIncludeProviderAndAccountIdentity() {
        let accountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9))

        XCTAssertEqual(
            WidgetAccountIdentifier.provider(.cursor).rawValue,
            "provider:Cursor"
        )
        XCTAssertEqual(
            WidgetAccountIdentifier.account(service: .claudeCode, id: accountID).rawValue,
            "account:Claude Code:00000000-0000-0000-0000-000000000009"
        )
        XCTAssertEqual(WidgetAccountIdentifier.provider(.cursor).service, .cursor)
        XCTAssertEqual(
            WidgetAccountIdentifier.account(service: .claudeCode, id: accountID).service,
            .claudeCode
        )
        XCTAssertNil(WidgetAccountIdentifier(rawValue: "removed").service)
    }

    func testOlderEncodedPreferencesUseDefaultsForMissingFields() throws {
        let legacyData = try JSONSerialization.data(withJSONObject: [:])

        let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: legacyData)

        XCTAssertEqual(decoded, .defaults)
    }

    /// An enum case this build does not know degrades that one field, never the
    /// whole preference set.
    ///
    /// The app and the widget extension read the same App Group value, so the
    /// two sides are only ever as aligned as the user's last update let them be.
    /// `decodeIfPresent` tolerates a *missing* key; a present key holding a
    /// future raw value still threw, the store's `try?` swallowed it into
    /// `.defaults`, and the next `update(_:)` wrote that reset back to disk —
    /// turning a one-field skew into a silent wipe of every preference.
    func testUnknownEnumCaseDegradesOnlyTheUnrecognizedField() throws {
        let account = WidgetAccountIdentifier.account(service: .claudeCode, id: UUID())
        var written = WidgetPreferences.defaults
        written.accountSelection = .explicit([account])
        written.displayMode = .remaining
        written.visibleQuotaWindows = [.weekly, .session]
        written.showsResetTime = true
        written.accountOrdering = .urgency

        let data = try encoded(written) { object in
            object["accountOrdering"] = "leastRecentlyUsed"
            object["visibleQuotaWindows"] = [
                WidgetQuotaWindow.weekly.rawValue,
                "monthlyRollup"
            ]
        }

        let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: data)

        XCTAssertEqual(decoded.accountSelection.explicitIdentifiers, [account])
        XCTAssertEqual(decoded.displayMode, .remaining)
        XCTAssertEqual(decoded.visibleQuotaWindows, [.weekly])
        XCTAssertTrue(decoded.showsResetTime)
        XCTAssertEqual(decoded.accountOrdering, WidgetPreferences.defaults.accountOrdering)
    }

    /// An unknown display mode falls back to the default; every other field the
    /// user chose is still theirs.
    func testUnknownDisplayModeFallsBackWithoutDiscardingOtherPreferences() throws {
        var written = WidgetPreferences.defaults
        written.displayMode = .remaining
        written.showsFreshness = true
        written.accountOrdering = .urgency

        let data = try encoded(written) { $0["displayMode"] = "perAccountAverage" }

        let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: data)

        XCTAssertEqual(decoded.displayMode, WidgetPreferences.defaults.displayMode)
        XCTAssertTrue(decoded.showsFreshness)
        XCTAssertEqual(decoded.accountOrdering, .urgency)
    }

    /// An unknown selection mode must not throw away the identifiers stored
    /// beside it — the selection is the one field here the user typed by hand.
    /// Identifiers present imply an explicit selection; none imply `.all`.
    func testUnknownAccountSelectionModeKeepsTheStoredIdentifiers() throws {
        let account = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        var written = WidgetPreferences.defaults
        written.accountSelection = .explicit([account])

        let data = try encoded(written) { object in
            guard var selection = object["accountSelection"] as? [String: Any] else { return }
            selection["mode"] = "urgentOnly"
            object["accountSelection"] = selection
        }

        let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: data)

        XCTAssertEqual(decoded.accountSelection.mode, .explicit)
        XCTAssertEqual(decoded.accountSelection.explicitIdentifiers, [account])
    }

    /// The store must not reset on a future enum case, and the next mutation
    /// must persist the preferences that survived rather than the wipe.
    func testStoredPreferencesSurviveAFutureEnumCaseAcrossTheNextUpdate() throws {
        var written = WidgetPreferences.defaults
        written.displayMode = .remaining
        written.showsFreshness = true
        written.accountOrdering = .urgency
        let data = try encoded(written) { $0["accountOrdering"] = "leastRecentlyUsed" }
        defaults.set(data, forKey: WidgetPreferencesStore.storageKey)

        let store = makeStore()

        XCTAssertEqual(store.preferences.displayMode, .remaining)
        XCTAssertTrue(store.preferences.showsFreshness)
        XCTAssertEqual(store.preferences.accountOrdering, WidgetPreferences.defaults.accountOrdering)

        store.setShowsResetTime(true)
        let reloaded = makeStore()

        XCTAssertEqual(reloaded.preferences.displayMode, .remaining)
        XCTAssertTrue(reloaded.preferences.showsFreshness)
        XCTAssertTrue(reloaded.preferences.showsResetTime)
    }

    /// Re-encodes a known-good value and edits the JSON, so the fixture can
    /// never drift from the real wire format.
    private func encoded(
        _ preferences: WidgetPreferences,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func makeStore() -> WidgetPreferencesStore {
        WidgetPreferencesStore(userDefaults: defaults, reloadTimelines: {})
    }

    private func candidate(
        service: ServiceType,
        accountOrder: Int,
        isProviderEnabled: Bool = true,
        isAccountEnabled: Bool = true,
        isAvailable: Bool = true,
        urgency: Double = 0
    ) -> WidgetAccountCandidate {
        WidgetAccountCandidate(
            identifier: .account(service: service, id: UUID()),
            service: service,
            accountOrder: accountOrder,
            isProviderEnabled: isProviderEnabled,
            isAccountEnabled: isAccountEnabled,
            isAvailable: isAvailable,
            urgency: urgency
        )
    }
}
