import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Covers the settings sidebar's provider rows — the navigation that replaced
/// the segmented provider picker inside the Providers page.
///
/// The load-bearing rule is that the sidebar's Providers group is driven by the
/// *tracked* set, never `ServiceType.allCases`: the group stays a handful of
/// rows no matter how many providers ship, and "All Providers" is what keeps
/// every untracked one reachable.
@MainActor
final class SettingsSidebarNavigationTests: XCTestCase {
    // MARK: - Sidebar rows

    func testProviderRowsListOnlyTrackedProvidersInDisplayOrder() {
        XCTAssertEqual(
            SettingsSidebarModel.trackedProviders(enabledServices: [.grok, .claudeCode, .cursor]),
            [.claudeCode, .cursor, .grok],
            "provider rows follow ServiceType.sortOrder, not Set iteration order"
        )
    }

    func testProviderRowsExcludeUntrackedProviders() {
        let rows = SettingsSidebarModel.trackedProviders(enabledServices: [.claudeCode])

        XCTAssertEqual(rows, [.claudeCode])
        XCTAssertFalse(rows.contains(.codexCli), "a hidden provider must not take a sidebar row")
    }

    func testProviderRowsCollapseToNothingWhenEveryProviderIsUntracked() {
        XCTAssertTrue(SettingsSidebarModel.trackedProviders(enabledServices: []).isEmpty)
    }

    /// The scaling guarantee: the sidebar group never grows past what the user
    /// actually tracks, even if the catalog is an order of magnitude larger.
    func testProviderRowCountTracksTheEnabledSetRatherThanTheCatalog() {
        let tracked: Set<ServiceType> = [.claudeCode, .codexCli]

        XCTAssertEqual(
            SettingsSidebarModel.trackedProviders(enabledServices: tracked).count,
            tracked.count
        )
        XCTAssertLessThan(
            SettingsSidebarModel.trackedProviders(enabledServices: tracked).count,
            ServiceType.allCases.count
        )
    }

    func testAppPagesDropProvidersBecauseItMovedUnderTheProvidersGroup() {
        XCTAssertEqual(
            SettingsSidebarModel.appPages,
            [.general, .widget, .apiUsage, .cost, .automation, .about]
        )
        XCTAssertFalse(SettingsSidebarModel.appPages.contains(.providers))
    }

    /// Every settings page still has exactly one sidebar home — the app pages
    /// group, or the "All Providers" row at the foot of the Providers group.
    func testEverySettingsPageStaysReachableFromTheSidebar() {
        let reachable = Set(SettingsSidebarModel.appPages + [SettingsSidebarModel.catalogPage])

        XCTAssertEqual(reachable, Set(SettingsSection.allCases))
        XCTAssertEqual(SettingsSidebarModel.catalogPage, .providers)
    }

    // MARK: - Selection identity

    func testSidebarItemIdentifiersNeverCollideAcrossSectionsAndProviders() {
        let items = SettingsSection.allCases.map(SettingsSidebarItem.section)
            + ServiceType.allCases.map(SettingsSidebarItem.provider)
        let ids = items.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "a provider row must never share a List tag with a page")
    }

    // MARK: - Navigation store

    func testSelectingAProviderRoutesToThatProvidersPage() {
        let navigation = DashboardNavigationStore.shared
        navigation.openSettings(.general)

        navigation.selectSettingsItem(.provider(.cursor))

        XCTAssertEqual(navigation.selectedSettingsProvider, .cursor)
        XCTAssertEqual(navigation.settingsSidebarItem, .provider(.cursor))
    }

    func testSelectingAPageClearsTheFocusedProvider() {
        let navigation = DashboardNavigationStore.shared
        navigation.selectSettingsItem(.provider(.grok))

        navigation.selectSettingsItem(.section(.widget))

        XCTAssertNil(navigation.selectedSettingsProvider)
        XCTAssertEqual(navigation.settingsSidebarItem, .section(.widget))
    }

    /// ⌘, and the menu-bar deep links go through `openSettings`; landing on a
    /// page must never leave a stale provider selected underneath it.
    func testOpeningSettingsClearsAnyFocusedProvider() {
        let navigation = DashboardNavigationStore.shared
        navigation.selectSettingsItem(.provider(.claudeCode))

        navigation.openSettings(.about)

        XCTAssertNil(navigation.selectedSettingsProvider)
        XCTAssertEqual(navigation.settingsSidebarItem, .section(.about))
    }

    /// Turning a provider off from its own page removes its sidebar row, so the
    /// selection has to land somewhere — the All Providers list, where it can be
    /// turned back on.
    func testUntrackingTheSelectedProviderFallsBackToAllProviders() {
        let navigation = DashboardNavigationStore.shared
        navigation.selectSettingsItem(.provider(.cursor))

        navigation.settingsProvidersChanged(enabledServices: [.claudeCode, .codexCli])

        XCTAssertNil(navigation.selectedSettingsProvider)
        XCTAssertEqual(navigation.settingsSidebarItem, .section(.providers))
    }

    func testTrackingOtherProvidersKeepsTheCurrentSelection() {
        let navigation = DashboardNavigationStore.shared
        navigation.selectSettingsItem(.provider(.cursor))

        navigation.settingsProvidersChanged(enabledServices: [.cursor, .grok])

        XCTAssertEqual(navigation.selectedSettingsProvider, .cursor)
    }

    // MARK: - Rendering

    func testProviderCatalogListsEveryProviderSoUntrackedOnesStayReachable() {
        XCTAssertEqual(
            ProviderCatalogSettingsView.catalog,
            ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        )

        let hostingView = NSHostingView(rootView: ProviderCatalogSettingsView().frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testProviderPageRendersWithoutAnEmbeddedProviderPicker() {
        let hostingView = NSHostingView(rootView: ProviderSettingsView(service: .claudeCode).frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    override func tearDown() async throws {
        DashboardNavigationStore.shared.closeSettings()
        DashboardNavigationStore.shared.selectSettingsItem(.section(.general))
        try await super.tearDown()
    }
}
