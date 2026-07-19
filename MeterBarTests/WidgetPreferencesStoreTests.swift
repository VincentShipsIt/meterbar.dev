import Foundation
import MeterBarShared
import XCTest

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
    }

    func testPreferencesPersistAcrossRelaunch() {
        let claude = WidgetAccountIdentifier.account(service: .claudeCode, id: UUID())
        let codex = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        let store = makeStore()

        store.setSelectedAccounts([claude, codex])
        store.setDisplayMode(.remaining)
        store.setVisibleQuotaWindows([.session, .weekly])
        store.setShowsResetTime(true)
        store.setShowsFreshness(true)
        store.setAccountOrdering(.urgency)

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.preferences.accountSelection.explicitIdentifiers, [claude, codex])
        XCTAssertEqual(reloaded.preferences.displayMode, .remaining)
        XCTAssertEqual(reloaded.preferences.visibleQuotaWindows, [.session, .weekly])
        XCTAssertTrue(reloaded.preferences.showsResetTime)
        XCTAssertTrue(reloaded.preferences.showsFreshness)
        XCTAssertEqual(reloaded.preferences.accountOrdering, .urgency)
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
    }

    func testOlderEncodedPreferencesUseDefaultsForMissingFields() throws {
        let legacyData = try JSONSerialization.data(withJSONObject: [:])

        let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: legacyData)

        XCTAssertEqual(decoded, .defaults)
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
