import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Guards the C1 split of `UsageDashboardView.swift` into per-section views.
///
/// The split moved the shared enums into `DashboardNavigation.swift` and lifted
/// three previously-inlined pieces of logic out of the 807-line view body so they
/// can be asserted directly: the section → refresh-target map (which the toolbar
/// spinner, the Refresh action, and the missing-days top-up each used to encode
/// separately), the Automation feature gate, and the two trailing-status strings.
@MainActor
final class DashboardSectionSplitTests: XCTestCase {
    // MARK: - Refresh targets

    func testEverySectionMapsToItsRefreshTarget() {
        let targets = DashboardSection.allCases.map { ($0, $0.refreshTarget) }

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: targets),
            [
                .overview: .usage,
                .limits: .usage,
                .diagnostics: .usage,
                .costs: .costs,
                .share: .costs,
                .optimize: .costs,
                .status: .providerStatus,
            ]
        )
    }

    func testCostBackedSectionsShareTheCostRefreshTarget() {
        // The toolbar spinner, Refresh, and the missing-days top-up must agree on
        // which pages are cost-backed; they used to encode this list three times.
        let costBacked = DashboardSection.allCases.filter { $0.refreshTarget == .costs }

        XCTAssertEqual(Set(costBacked), [.costs, .share, .optimize])
    }

    func testOnlyTheCostsPageAlsoRefreshesApiUsage() {
        let apiBacked = DashboardSection.allCases.filter(\.refreshesApiUsage)

        XCTAssertEqual(apiBacked, [.costs])
    }

    func testEveryDashboardSectionCarriesAnIconAndSubtitle() {
        for section in DashboardSection.allCases {
            XCTAssertFalse(section.iconName.isEmpty, "\(section) lost its sidebar icon")
            XCTAssertFalse(section.titlebarSubtitle.isEmpty, "\(section) lost its titlebar subtitle")
        }
    }

    // MARK: - Settings feature gate

    func testAutomationSettingsStayHiddenWhileSessionWakeIsOff() {
        let available = SettingsSection.available(sessionWakeEnabled: false)

        XCTAssertFalse(available.contains(.automation))
        XCTAssertEqual(available, SettingsSection.allCases.filter { $0 != .automation })
    }

    func testAutomationSettingsAppearWhenSessionWakeIsOn() {
        XCTAssertEqual(SettingsSection.available(sessionWakeEnabled: true), SettingsSection.allCases)
    }

    func testEverySettingsSectionCarriesAnIcon() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.iconName.isEmpty, "\(section) lost its sidebar icon")
        }
    }

    // MARK: - Navigation store

    func testNavigateSelectsTheSectionAndLeavesSettingsMode() {
        let navigation = DashboardNavigationStore.shared
        defer { restore(navigation) }

        navigation.openSettings(.providers)
        navigation.navigate(to: .limits, focusedProviderID: "codex")

        XCTAssertEqual(navigation.selectedSection, .limits)
        XCTAssertEqual(navigation.focusedProviderID, "codex")
        XCTAssertFalse(navigation.isShowingSettings)
    }

    func testNavigateWithoutAFocusClearsThePreviousFocusedProvider() {
        let navigation = DashboardNavigationStore.shared
        defer { restore(navigation) }

        navigation.navigate(to: .limits, focusedProviderID: "codex")
        navigation.navigate(to: .overview)

        XCTAssertNil(navigation.focusedProviderID)
    }

    func testOpenThenCloseSettingsReturnsToTheMonitoringDashboard() {
        let navigation = DashboardNavigationStore.shared
        defer { restore(navigation) }

        navigation.navigate(to: .costs)
        navigation.openSettings(.widget)

        XCTAssertTrue(navigation.isShowingSettings)
        XCTAssertEqual(navigation.selectedSettingsSection, .widget)

        navigation.closeSettings()

        XCTAssertFalse(navigation.isShowingSettings)
        XCTAssertEqual(navigation.selectedSection, .costs, "settings mode must not lose the page underneath")
    }

    // MARK: - Trailing status strings

    func testCostRefreshStatusPrefersScanningOverTheMissingDayTopUp() {
        XCTAssertEqual(
            DashboardCostsSection.refreshStatusText(isScanning: true, isRefreshingMissingDays: true),
            "Scanning..."
        )
        XCTAssertEqual(
            DashboardCostsSection.refreshStatusText(isScanning: false, isRefreshingMissingDays: true),
            "Updating..."
        )
        XCTAssertNil(
            DashboardCostsSection.refreshStatusText(isScanning: false, isRefreshingMissingDays: false)
        )
    }

    func testStatusPageSummaryReportsRefreshFirst() {
        XCTAssertEqual(
            DashboardStatusSection.summary(isRefreshing: true, issueCount: 3, reportCount: 0),
            "Refreshing..."
        )
    }

    func testStatusPageSummaryOnlyClaimsAllOperationalWithACompleteSweep() {
        XCTAssertEqual(
            DashboardStatusSection.summary(
                isRefreshing: false,
                issueCount: 0,
                reportCount: ServiceType.allCases.count
            ),
            "All operational"
        )
        XCTAssertNil(
            DashboardStatusSection.summary(
                isRefreshing: false,
                issueCount: 0,
                reportCount: ServiceType.allCases.count - 1
            ),
            "a partial sweep must not claim every provider is healthy"
        )
    }

    func testStatusPageSummaryPluralizesIssues() {
        XCTAssertEqual(
            DashboardStatusSection.summary(isRefreshing: false, issueCount: 1, reportCount: 1),
            "1 issue"
        )
        XCTAssertEqual(
            DashboardStatusSection.summary(isRefreshing: false, issueCount: 4, reportCount: 5),
            "4 issues"
        )
    }

    // MARK: - Share card sources

    func testEnabledSourceLabelsCoverOnlyTheLogBackedProviders() {
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: Set(ServiceType.allCases)),
            ["Codex logs", "Claude JSONL", "Cursor local state"]
        )
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: [.claudeCode]),
            ["Claude JSONL"]
        )
        XCTAssertTrue(
            DashboardShareSection.enabledSourceLabels(for: [.openRouter, .grok]).isEmpty,
            "API-only providers contribute no local log source"
        )
    }

    // MARK: - Extracted section views still render

    func testOverviewSectionRenders() {
        let view = DashboardOverviewSection(
            snapshots: [snapshot()],
            tightestLimit: snapshot().limits.first,
            enabledSourceCount: 2,
            costSummary: nil,
            onSelectProvider: { _ in }
        )

        assertRenders(view)
    }

    func testCostsSectionRenders() {
        assertRenders(DashboardCostsSection(summary: nil, quotaSnapshot: { _ in nil }))
    }

    func testStatusSectionRenders() {
        assertRenders(DashboardStatusSection())
    }

    func testDiagnosticsSectionRenders() {
        assertRenders(DashboardDiagnosticsSection(reports: .constant([]), isRunning: .constant(false)))
    }

    func testShareSectionRenders() {
        assertRenders(
            DashboardShareSection(
                costSummary: nil,
                providerTitles: ["Codex"],
                viewportWidth: 900,
                horizontalInsets: 48,
                generatedAt: .constant(Date(timeIntervalSince1970: 1_700_000_000)),
                shareStatus: .constant(nil)
            )
        )
    }

    /// The pages are `switch` branches, so anything they own as `@State` is
    /// destroyed on navigation. These two carried shell state before the split
    /// and must keep taking it from outside, or Diagnostics re-runs its whole
    /// readiness sweep — and Share drops its toast — on every revisit.
    func testNavigationScopedStateStaysOwnedByTheShell() {
        let diagnostics = DashboardDiagnosticsSection(reports: .constant([]), isRunning: .constant(false))
        assertIsBinding(diagnostics, "_readinessReports", Binding<[ProviderReadiness]>.self)
        assertIsBinding(diagnostics, "_isRunningDiagnostics", Binding<Bool>.self)

        let share = DashboardShareSection(
            costSummary: nil,
            providerTitles: [],
            viewportWidth: 900,
            horizontalInsets: 48,
            generatedAt: .constant(Date(timeIntervalSince1970: 1_700_000_000)),
            shareStatus: .constant(nil)
        )
        assertIsBinding(share, "_shareStatus", Binding<String?>.self)
    }

    private func assertIsBinding<Wrapper>(
        _ view: some View,
        _ label: String,
        _ expected: Wrapper.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stored = Mirror(reflecting: view).children.first { $0.label == label }?.value
        XCTAssertNotNil(stored, "\(label) is gone — did it move back onto the page?", file: file, line: line)
        XCTAssertTrue(
            stored is Wrapper,
            "\(label) must be a \(expected), not page-local @State that navigation destroys.",
            file: file,
            line: line
        )
    }

    func testDashboardShellStillRenders() {
        assertRenders(UsageDashboardView(), width: 1000, height: 700)
    }

    // MARK: - Helpers

    private func assertRenders(
        _ view: some View,
        width: CGFloat = 820,
        height: CGFloat = 600,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0, file: file, line: line)
    }

    private func snapshot() -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: "codex",
            title: "Codex",
            service: .codexCli,
            updatedAt: Date(),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil,
            fableActivity: nil
        )
    }

    private func restore(_ navigation: DashboardNavigationStore) {
        navigation.navigate(to: .overview)
    }
}
