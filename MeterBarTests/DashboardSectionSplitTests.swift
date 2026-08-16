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

    func testLimitsKeepsDisplayOrderWhenAProviderIsFocused() {
        let snapshots = [
            snapshot(id: "claude", title: "Claude", service: .claudeCode),
            snapshot(id: "codex", title: "Codex", service: .codexCli),
            snapshot(id: "cursor", title: "Cursor", service: .cursor)
        ]

        XCTAssertEqual(
            DashboardLimitsLayout.orderedSnapshots(snapshots, focusedProviderID: "cursor").map(\.id),
            snapshots.map(\.id)
        )
        XCTAssertNotEqual(
            DashboardLimitsLayout.orderedSnapshots(snapshots, focusedProviderID: "cursor").first?.id,
            "cursor",
            "clicking an Overview card must not pin that provider to the top-left of Limits"
        )
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

    /// The estimate card's subtitle names the window and nothing else: refresh
    /// state belongs on the trailing edge, matching the spend card rather than
    /// replacing the card's own caption. The window follows the page's 7/30-day
    /// toggle.
    func testCostOverviewSubtitleIsWindowOnlyAndStatusMatchesTheOtherCards() {
        XCTAssertEqual(CostWindowSelection.month.subtitle, "Last 30 days")
        XCTAssertEqual(CostWindowSelection.week.subtitle, "Last 7 days")

        for isScanning in [true, false] {
            for isRefreshingMissingDays in [true, false] {
                XCTAssertEqual(
                    CostOverviewStatusCard.headerStatus(
                        isScanning: isScanning,
                        isRefreshingMissingDays: isRefreshingMissingDays
                    ),
                    DashboardCostsSection.refreshStatusText(
                        isScanning: isScanning,
                        isRefreshingMissingDays: isRefreshingMissingDays
                    ),
                    "estimate card must reuse the page's trailing status wording"
                )
            }
        }
    }

    /// The model list leads with the three biggest spenders; the rest live
    /// behind an explicit control. No control at all when nothing is hidden.
    func testModelSpendListCompactsPastTheTopThree() {
        XCTAssertEqual(CostSpendCharts.compactModelLimit, 3)
        XCTAssertNil(CostSpendCharts.modelToggleTitle(showingAll: false, totalCount: 3))
        XCTAssertNil(CostSpendCharts.modelToggleTitle(showingAll: false, totalCount: 0))
        XCTAssertEqual(
            CostSpendCharts.modelToggleTitle(showingAll: false, totalCount: 12),
            "Show all 12 models"
        )
        XCTAssertEqual(
            CostSpendCharts.modelToggleTitle(showingAll: true, totalCount: 12),
            "Show top 3"
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

    /// The refresh control used to be a flat glass label that only greyed out
    /// while a sweep ran, so the button itself never acknowledged the press.
    /// The title now carries that state next to the spinner.
    func testRefreshButtonTitleReportsTheInFlightSweep() {
        XCTAssertEqual(DashboardStatusSection.refreshButtonTitle(isRefreshing: false), "Refresh")
        XCTAssertEqual(DashboardStatusSection.refreshButtonTitle(isRefreshing: true), "Refreshing...")
    }

    /// The card's trailing summary already says "Refreshing..."; the button must
    /// not be the only thing that changes, but it also must not be silent.
    func testRefreshButtonHelpTextMatchesTheButtonState() {
        XCTAssertEqual(
            DashboardStatusSection.refreshButtonHelp(isRefreshing: false),
            "Refresh every provider status page"
        )
        XCTAssertEqual(
            DashboardStatusSection.refreshButtonHelp(isRefreshing: true),
            "Refreshing provider status pages"
        )
    }

    // MARK: - Overview masonry

    /// Round-robin keeps left-to-right reading order across a row while the
    /// columns themselves pack independently, which is the point of the
    /// masonry: a short card no longer pads itself out to a tall neighbour.
    func testMasonryColumnsDealCardsAcrossColumnsInReadingOrder() {
        let columns = ProviderMasonryLayout.columns(Array(0..<5), columnCount: 2)

        XCTAssertEqual(columns, [[0, 2, 4], [1, 3]])
    }

    /// Column counts never differ by more than one, so no column runs long
    /// enough to reintroduce the ragged bottom edge.
    func testMasonryColumnsStayBalancedWithinOneCard() {
        let columns = ProviderMasonryLayout.columns(Array(0..<7), columnCount: 3)

        let counts = columns.map(\.count)
        XCTAssertEqual(counts, [3, 2, 2])
        XCTAssertEqual(counts.reduce(0, +), 7)
    }

    /// A single provider must still occupy one column's width rather than
    /// stretching across the page, so empty trailing columns are preserved.
    func testMasonryColumnsKeepEmptyTrailingColumnsForWidth() {
        let columns = ProviderMasonryLayout.columns([0], columnCount: 2)

        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0], [0])
        XCTAssertTrue(columns[1].isEmpty)
    }

    func testMasonryColumnsClampsNonPositiveColumnCounts() {
        XCTAssertEqual(ProviderMasonryLayout.columns([1, 2], columnCount: 0), [[1, 2]])
    }

    // MARK: - Overview masonry placement

    /// The columns used to be real `VStack`s, which made a card's SwiftUI
    /// identity depend on which column it was dealt into — a membership change
    /// anywhere in the list moved cards across columns and discarded their
    /// `@State`. Placement is geometry now, from one container, so the same
    /// deal has to come out of the frames instead: even indices stacked down
    /// the left column, odd down the right, each column packing independently.
    func testMasonryFramesStackEachColumnIndependently() {
        let frames = ProviderMasonryLayout.frames(
            heights: [100, 30, 40, 20, 60],
            containerWidth: 210,
            columnCount: 2,
            spacing: 10
        )

        XCTAssertEqual(frames.map(\.origin.x), [0, 110, 0, 110, 0])
        // Left column stacks 100, 40, 60 with a gutter after each. The right
        // column packs on its own, so index 3 sits directly under index 1's 30
        // rather than being pushed down by the tall card beside it.
        XCTAssertEqual(frames.map(\.origin.y), [0, 0, 110, 40, 160])
    }

    /// Each card gets exactly one column's width; the gutters come out of the
    /// container, not out of the cards.
    func testMasonryFramesSplitTheContainerWidthMinusGutters() {
        let frames = ProviderMasonryLayout.frames(
            heights: [10, 10, 10],
            containerWidth: 320,
            columnCount: 3,
            spacing: 16
        )

        XCTAssertEqual(frames.map(\.width), [96, 96, 96])
        XCTAssertEqual(frames.map(\.origin.x), [0, 112, 224])
    }

    /// The section is as tall as its tallest column — the short column must not
    /// pad the layout out to a ragged bottom edge.
    func testMasonryHeightIsTheTallestColumn() {
        let frames = ProviderMasonryLayout.frames(
            heights: [100, 30, 40],
            containerWidth: 210,
            columnCount: 2,
            spacing: 10
        )

        XCTAssertEqual(ProviderMasonryLayout.totalHeight(of: frames), 150)
    }

    /// A single card still occupies one column rather than stretching across
    /// the page, matching the empty-trailing-column rule above.
    func testMasonryFramesKeepASingleCardAtColumnWidth() {
        let frames = ProviderMasonryLayout.frames(
            heights: [42],
            containerWidth: 210,
            columnCount: 2,
            spacing: 10
        )

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 100, height: 42))
    }

    // MARK: - Week-row date labels

    /// The week-row gutter label is locale-templated ("MMMd"), so the exact
    /// ordering varies by machine locale — but the day number must survive in
    /// every arrangement ("10 Jul", "Jul 10", "7月10日").
    func testMonthDayLabelCarriesTheDayNumberInAnyLocale() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let label = DashboardDateFormat.monthDay(date)

        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(
            label.contains("\(Calendar.current.component(.day, from: date))"),
            "label must include the day of month: \(label)"
        )
    }

    // MARK: - Overview "Use next" tile

    private func rankedRecommendation(
        sessionUsed: Double = 8,
        weeklyUsed: Double = 8
    ) -> ProviderRecommendation {
        ProviderRecommendationPlanner.rank(
            candidates: [
                ProviderRecommendationCandidate(
                    id: "codex",
                    name: "Codex",
                    service: .codexCli,
                    displayOrder: 0,
                    sessionLimit: UsageLimit(used: sessionUsed, total: 100, resetTime: nil),
                    weeklyLimit: UsageLimit(used: weeklyUsed, total: 100, resetTime: nil),
                    lastUpdated: Date(timeIntervalSince1970: 1_750_000_000)
                ),
            ],
            now: Date(timeIntervalSince1970: 1_750_000_100)
        )
    }

    func testUseNextTileLeadsWithTheTopRankedProvider() throws {
        let recommendation = rankedRecommendation()
        let tile = DashboardOverviewSection.useNextTile(for: recommendation)
        let top = try XCTUnwrap(recommendation.rows.first)

        XCTAssertEqual(tile.value, top.name)
        XCTAssertTrue(
            tile.caption.contains(top.headroomText),
            "the caption must carry the headroom that earned the rank: \(tile.caption)"
        )
        XCTAssertTrue(tile.caption.contains(top.windowTitle))
        XCTAssertEqual(tile.band, top.band)
    }

    func testUseNextTileSaysSoWhenEveryWindowIsSpent() {
        let recommendation = rankedRecommendation(sessionUsed: 100, weeklyUsed: 100)
        let tile = DashboardOverviewSection.useNextTile(for: recommendation)

        XCTAssertEqual(tile.value, "Every window spent")
        XCTAssertEqual(tile.band, .exhausted)
    }

    func testUseNextTileFallsBackWhenNothingIsRankable() {
        let tile = DashboardOverviewSection.useNextTile(
            for: ProviderRecommendationPlanner.rank(candidates: [], now: Date())
        )

        XCTAssertEqual(tile.value, "No data")
        XCTAssertEqual(tile.caption, "Waiting for provider refresh")
        XCTAssertNil(tile.band)
    }

    // MARK: - Optimize KPI tiles

    /// The four KPI tiles are one glanceable band of headline numbers, not a
    /// 2×2 block that pushes the token-burn chart below the fold.
    func testOptimizeKpiTilesSitOnASingleRow() {
        XCTAssertEqual(OptimizeInsightsView.kpiColumns.count, 4)
    }

    /// A quiet week rendered as a bare `0` next to a caption boasting billions
    /// over 30 days reads as a broken counter. An empty window has to say so.
    func testRecentWindowTileNamesAnEmptyWeekInsteadOfShowingZero() {
        let empty = OptimizeInsightsView.recentWindowTile(tokens7Day: 0, tokens30Day: 32_400_000_000)

        XCTAssertEqual(empty.value, "None")
        XCTAssertTrue(
            empty.caption.contains("over 30 days"),
            "the 30-day total is the context that makes an empty week legible"
        )
        XCTAssertNotEqual(empty.value, UsageFormat.tokens(0))
    }

    func testRecentWindowTileReportsNoUsageAtAllWhenBothWindowsAreEmpty() {
        let blank = OptimizeInsightsView.recentWindowTile(tokens7Day: 0, tokens30Day: 0)

        XCTAssertEqual(blank.value, "None")
        XCTAssertFalse(
            blank.caption.contains("over 30 days"),
            "quoting an empty 30-day total explains nothing"
        )
    }

    func testRecentWindowTileKeepsTheNormalReadoutWhenThereIsUsage() {
        let busy = OptimizeInsightsView.recentWindowTile(tokens7Day: 1_200_000, tokens30Day: 9_000_000)

        XCTAssertEqual(busy.value, UsageFormat.tokens(1_200_000))
        XCTAssertEqual(busy.caption, "\(UsageFormat.tokens(9_000_000)) over 30 days")
    }

    /// The window KPI tile follows the page's 7/30-day toggle: the week keeps
    /// the empty-week wording above; the month reports the 30-day total.
    func testWindowTileFollowsTheSelectedWindow() {
        let week = OptimizeInsightsView.windowTile(
            selection: .week,
            tokens7Day: 1_200_000,
            tokens30Day: 9_000_000
        )
        XCTAssertEqual(week.title, "Last 7 days")
        XCTAssertEqual(week.value, UsageFormat.tokens(1_200_000))
        XCTAssertEqual(week.caption, "\(UsageFormat.tokens(9_000_000)) over 30 days")

        let month = OptimizeInsightsView.windowTile(
            selection: .month,
            tokens7Day: 1_200_000,
            tokens30Day: 9_000_000
        )
        XCTAssertEqual(month.title, "Last 30 days")
        XCTAssertEqual(month.value, UsageFormat.tokens(9_000_000))
        XCTAssertEqual(month.caption, "tokens in the last 30 days")

        let emptyMonth = OptimizeInsightsView.windowTile(selection: .month, tokens7Day: 0, tokens30Day: 0)
        XCTAssertEqual(emptyMonth.value, "None")
        XCTAssertEqual(emptyMonth.caption, "no tokens recorded in the last 30 days")
    }

    // MARK: - Share card sources

    func testEnabledSourceLabelsCoverOnlyTheLogBackedProviders() {
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: Set(ServiceType.allCases)),
            ["Claude JSONL", "Codex logs", "Grok JSONL"]
        )
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: [.claudeCode]),
            ["Claude JSONL"]
        )
        XCTAssertEqual(
            DashboardShareSection.enabledSourceLabels(for: [.openRouter, .grok]),
            ["Grok JSONL"]
        )
        XCTAssertTrue(
            DashboardShareSection.enabledSourceLabels(for: [.openRouter, .cursor]).isEmpty,
            "API-only providers contribute no local log source"
        )
    }

    // MARK: - Share card freshness

    func testShareScanStatusMatchesTheCostCardsExactly() {
        for isScanning in [true, false] {
            for isRefreshingMissingDays in [true, false] {
                XCTAssertEqual(
                    DashboardShareSection.scanStatusText(
                        isScanning: isScanning,
                        isRefreshingMissingDays: isRefreshingMissingDays
                    ),
                    DashboardCostsSection.refreshStatusText(
                        isScanning: isScanning,
                        isRefreshingMissingDays: isRefreshingMissingDays
                    ),
                    "share preview and cost cards must announce the same scan state"
                )
            }
        }
    }

    func testExportStatusWarnsThatTotalsAreStillSettlingDuringAScan() {
        XCTAssertEqual(
            DashboardShareSection.exportStatus("PNG copied", isRefreshInProgress: true),
            "PNG copied — totals still updating"
        )
        XCTAssertEqual(
            DashboardShareSection.exportStatus("Caption copied", isRefreshInProgress: false),
            "Caption copied"
        )
    }

    // MARK: - Extracted section views still render

    func testOverviewSectionRenders() {
        let view = DashboardOverviewSection(
            snapshots: [snapshot()],
            tightestLimit: snapshot().limits.first,
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

    private func snapshot(
        id: String = "codex",
        title: String = "Codex",
        service: ServiceType = .codexCli
    ) -> ProviderSnapshot {
        let weekly = UsageLimit(
            used: 40,
            total: 100,
            resetTime: Date().addingTimeInterval(3600),
            windowSeconds: 604_800
        )
        return ProviderSnapshot(
            id: id,
            title: title,
            service: service,
            updatedAt: Date(),
            limits: [
                SnapshotLimit(id: "weekly", kind: .weekly, title: "Weekly", usageLimit: weekly)
            ],
            emptyDetail: "Waiting for refresh",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil
        )
    }

    private func restore(_ navigation: DashboardNavigationStore) {
        navigation.navigate(to: .overview)
    }
}
