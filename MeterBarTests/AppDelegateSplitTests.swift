import AppKit
import Combine
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers the collaborators extracted out of `MeterBarApp.swift` (C1 split).
///
/// The extraction was a pure move, so these tests pin the behaviour that used to
/// be unreachable while it lived in private `AppDelegate` methods: menu titles
/// and structure, the status-item label/tooltip branches, the account-metrics
/// fallback rules, and the refresh-trigger fan-in.
@MainActor
final class AppDelegateSplitTests: XCTestCase {
    private static let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    // Menu construction only reads the selectors, so one placeholder is enough.
    private static let placeholderSelector = #selector(NSApplication.terminate(_:))

    private static let actions = StatusMenuBuilder.Actions(
        selectMenuBarAuto: placeholderSelector,
        selectMenuBarPin: placeholderSelector,
        selectMenuBarAllProviders: placeholderSelector,
        toggleShowInDock: placeholderSelector,
        openDashboard: placeholderSelector,
        refreshProviderStatuses: placeholderSelector,
        openProviderStatusPage: placeholderSelector,
        quit: placeholderSelector
    )

    // MARK: - MenuBarIconRenderer

    func testStatusDotColorMapsEveryIndicator() {
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .none), .systemGreen)
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .minor), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .maintenance), .systemOrange)
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .major), .systemRed)
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .critical), .systemRed)
        XCTAssertEqual(MenuBarIconRenderer.statusDotColor(for: .unknown), .tertiaryLabelColor)
    }

    func testMeterIconIsTemplateAtMenuBarSize() {
        let icon = MenuBarIconRenderer.meterIcon()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, MenuBarIconRenderer.iconSize)
    }

    // MARK: - StatusMenuBuilder

    func testStatusMenuHasDockDashboardStatusAndQuitItems() {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            status: StatusMenuBuilder.StatusSnapshot()
        )

        let menu = builder.makeMenu()

        XCTAssertEqual(menu.items.count, 7)
        XCTAssertEqual(menu.items[0].title, "Menu Bar Shows")
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Show in Dock")
        XCTAssertEqual(menu.items[2].state, .on)
        XCTAssertEqual(menu.items[3].title, "Open Usage Dashboard")
        XCTAssertEqual(menu.items[4].title, "Status Pages")
        XCTAssertNotNil(menu.items[4].submenu)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertEqual(menu.items[6].title, "Quit MeterBar")
        XCTAssertEqual(menu.items[6].keyEquivalent, "q")
    }

    func testStatusMenuDockItemReflectsHiddenDock() {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: false,
            status: StatusMenuBuilder.StatusSnapshot()
        )

        XCTAssertEqual(builder.makeMenu().items[2].state, .off)
    }

    func testProviderStatusMenuTitleUsesReportSummaryDescription() {
        let status = StatusMenuBuilder.StatusSnapshot(
            reports: [.claudeCode: Self.report(indicator: .minor, description: "Elevated errors")]
        )

        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuTitle(for: .claudeCode, status: status),
            "\(ServiceType.claudeCode.statusPageDisplayName) — Elevated errors"
        )
    }

    func testProviderStatusMenuTitleFallsBackToIndicatorLabel() {
        let status = StatusMenuBuilder.StatusSnapshot(
            reports: [.claudeCode: Self.report(indicator: .none, description: nil)]
        )

        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuTitle(for: .claudeCode, status: status),
            "\(ServiceType.claudeCode.statusPageDisplayName) — Operational"
        )
    }

    func testProviderStatusMenuTitleReportsUnavailableAndChecking() {
        let errored = StatusMenuBuilder.StatusSnapshot(errors: [.cursor: "offline"])
        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuTitle(for: .cursor, status: errored),
            "\(ServiceType.cursor.statusPageDisplayName) — Unavailable"
        )
        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuTitle(
                for: .cursor,
                status: StatusMenuBuilder.StatusSnapshot()
            ),
            "\(ServiceType.cursor.statusPageDisplayName) — Checking..."
        )
    }

    func testProviderStatusMenuIndicatorPrefersReportThenErrorThenUnknown() {
        let reported = StatusMenuBuilder.StatusSnapshot(
            reports: [.cursor: Self.report(indicator: .major, description: nil)]
        )
        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuIndicator(for: .cursor, status: reported),
            .major
        )
        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuIndicator(
                for: .cursor,
                status: StatusMenuBuilder.StatusSnapshot(errors: [.cursor: "offline"])
            ),
            .critical
        )
        XCTAssertEqual(
            StatusMenuBuilder.providerStatusMenuIndicator(
                for: .cursor,
                status: StatusMenuBuilder.StatusSnapshot()
            ),
            .unknown
        )
    }

    func testProviderStatusSubmenuListsSummaryComponentsAndOpenItem() {
        let report = Self.report(
            indicator: .minor,
            description: "Elevated errors",
            components: [
                ProviderStatusComponent(id: "a", name: "API", indicator: .minor, status: "degraded_performance"),
                ProviderStatusComponent(id: "b", name: "Console", indicator: .none, status: "operational")
            ]
        )
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            status: StatusMenuBuilder.StatusSnapshot(reports: [.claudeCode: report])
        )

        let submenu = builder.makeProviderStatusSubmenu(for: .claudeCode)

        // summary + separator + 2 components + separator + open item
        XCTAssertEqual(submenu.items.count, 6)
        XCTAssertEqual(submenu.items[0].title, "Elevated errors")
        XCTAssertFalse(submenu.items[0].isEnabled)
        XCTAssertTrue(submenu.items[1].isSeparatorItem)
        XCTAssertTrue(submenu.items[2].title.hasPrefix("API"))
        XCTAssertTrue(submenu.items[3].title.hasPrefix("Console"))
        XCTAssertEqual(
            submenu.items[5].title,
            "Open \(ServiceType.claudeCode.statusPageDisplayName) Status Page"
        )
        XCTAssertEqual(submenu.items[5].representedObject as? String, ServiceType.claudeCode.rawValue)
    }

    func testProviderStatusSubmenuShowsErrorAndCheckingPlaceholders() {
        let errored = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            status: StatusMenuBuilder.StatusSnapshot(errors: [.cursor: "Request timed out"])
        )
        let erroredItems = errored.makeProviderStatusSubmenu(for: .cursor).items
        XCTAssertEqual(erroredItems[0].title, "Request timed out")
        XCTAssertFalse(erroredItems[0].isEnabled)

        let pending = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            status: StatusMenuBuilder.StatusSnapshot()
        )
        XCTAssertEqual(pending.makeProviderStatusSubmenu(for: .cursor).items[0].title, "Checking status...")
    }

    func testStatusComponentMenuItemNestsGroupChildren() {
        let component = ProviderStatusComponent(
            id: "group",
            name: "Platform",
            indicator: .none,
            status: "operational",
            children: [
                ProviderStatusComponent(id: "child", name: "API", indicator: .none, status: "operational")
            ]
        )

        let item = StatusMenuBuilder.makeStatusComponentMenuItem(component)

        XCTAssertEqual(item.submenu?.items.count, 1)
        XCTAssertEqual(item.submenu?.items[0].title, "API  Operational")
        XCTAssertTrue(item.isEnabled)
    }

    func testStatusComponentMenuItemIsDisabledForLeafComponents() {
        let item = StatusMenuBuilder.makeStatusComponentMenuItem(
            ProviderStatusComponent(id: "leaf", name: "API", indicator: .none, status: "operational")
        )

        XCTAssertNil(item.submenu)
        XCTAssertFalse(item.isEnabled)
    }

    func testProviderStatusMenuListsEveryServiceAndARefreshItem() throws {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            status: StatusMenuBuilder.StatusSnapshot(isRefreshing: true)
        )

        let menu = builder.makeProviderStatusMenu()

        XCTAssertEqual(menu.items.count, ServiceType.allCases.count + 2)
        let refreshItem = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(refreshItem.title, "Refresh Status Pages")
        // A refresh already in flight disables the item instead of stacking work.
        XCTAssertFalse(refreshItem.isEnabled)
    }

    // MARK: - StatusItemRefreshTrigger

    func testRefreshTriggerFansInEverySource() {
        // One publisher per input that can change the menu-bar title: metrics,
        // the two account-metric maps, Claude accounts, Codex accounts, provider
        // visibility, parse health, and the label preferences.
        XCTAssertEqual(StatusItemRefreshTrigger.sources().count, 8)
    }

    func testRefreshTriggerPublisherEmitsOnSubscribe() {
        let expectation = expectation(description: "trigger emits")
        expectation.assertForOverFulfill = false
        var cancellables = Set<AnyCancellable>()

        StatusItemRefreshTrigger.publisher()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1)
        cancellables.removeAll()
    }

    // MARK: - StatusLimitProbeRequestBuilder

    func testClaudeMetricsPrefersAccountMetrics() {
        let account = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let accountMetrics = MetricsFixtures.claudeCode(sessionUsedPercent: 10)
        let providerMetrics = MetricsFixtures.claudeCode(sessionUsedPercent: 90)

        let resolved = StatusLimitProbeRequestBuilder.claudeMetrics(
            for: account,
            accountMetrics: [account.id: accountMetrics],
            providerMetrics: providerMetrics
        )

        XCTAssertEqual(resolved?.sessionLimit?.used, 10)
    }

    func testClaudeMetricsFallsBackToProviderOnlyForTheDefaultAccount() {
        let providerMetrics = MetricsFixtures.claudeCode(sessionUsedPercent: 90)

        let defaultResolved = StatusLimitProbeRequestBuilder.claudeMetrics(
            for: .defaultAccount,
            accountMetrics: [:],
            providerMetrics: providerMetrics
        )
        XCTAssertEqual(defaultResolved?.sessionLimit?.used, 90)

        let custom = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        XCTAssertNil(StatusLimitProbeRequestBuilder.claudeMetrics(
            for: custom,
            accountMetrics: [:],
            providerMetrics: providerMetrics
        ))
    }

    func testCodexMetricsFallsBackOnlyForASoleDefaultAccountWithoutAccountData() {
        let providerMetrics = MetricsFixtures.codexCli(sessionUsedPercent: 70)

        XCTAssertEqual(
            StatusLimitProbeRequestBuilder.codexMetrics(
                for: .defaultAccount,
                enabledAccountCount: 1,
                accountMetrics: [:],
                providerMetrics: providerMetrics
            )?.sessionLimit?.used,
            70
        )

        // A second enabled account means the provider-level snapshot is no
        // longer unambiguously the default account's.
        XCTAssertNil(StatusLimitProbeRequestBuilder.codexMetrics(
            for: .defaultAccount,
            enabledAccountCount: 2,
            accountMetrics: [:],
            providerMetrics: providerMetrics
        ))

        // Any account-level data at all wins over the fallback.
        let other = UUID()
        XCTAssertNil(StatusLimitProbeRequestBuilder.codexMetrics(
            for: .defaultAccount,
            enabledAccountCount: 1,
            accountMetrics: [other: MetricsFixtures.codexCli()],
            providerMetrics: providerMetrics
        ))
    }

    func testCandidatesStampSeedsWithTheProbedActivity() {
        let probed = Self.referenceDate
        let seed = StatusLimitCandidateSeed(
            key: "cursor",
            pinKey: "cursor:default:weekly",
            displayName: "Cursor",
            windowName: "Weekly",
            limit: UsageLimit(used: 42, total: 100, resetTime: nil),
            isAutoSelectable: true
        )
        let request = StatusLimitProbeRequest(seeds: [seed], probe: { probed })

        let candidates = StatusLimitProbeRequestBuilder.candidates(from: [request])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].key, "cursor")
        XCTAssertEqual(candidates[0].pinKey, "cursor:default:weekly")
        XCTAssertEqual(candidates[0].displayName, "Cursor")
        XCTAssertEqual(candidates[0].windowName, "Weekly")
        XCTAssertEqual(candidates[0].lastActivity, probed)
        XCTAssertTrue(candidates[0].isAutoSelectable)
    }

    func testCandidatesRunEachProbeOnceForAllOfItsSeeds() {
        var probeCount = 0
        let seeds = (0..<3).map { index in
            StatusLimitCandidateSeed(
                key: "claude:\(index)",
                pinKey: "claudeCode:default:\(index)",
                displayName: "Claude",
                windowName: "Session",
                limit: UsageLimit(used: Double(index), total: 100, resetTime: nil),
                isAutoSelectable: false
            )
        }
        let request = StatusLimitProbeRequest(seeds: seeds, probe: {
            probeCount += 1
            return nil
        })

        let candidates = StatusLimitProbeRequestBuilder.candidates(from: [request])

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(probeCount, 1)
    }

    func testMenuBarShowsSubmenuChecksAutoWhenNothingIsPinned() {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            menuBarShows: StatusMenuBuilder.MenuBarShowsSnapshot(
                mode: .merged,
                options: [StatusItemPinOption(id: "claude:1", title: "Work · Session")]
            ),
            status: StatusMenuBuilder.StatusSnapshot()
        )

        let items = builder.makeMenuBarShowsMenu().items

        // Auto + separator + one pinnable window + separator + All Providers
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].title, "Auto")
        XCTAssertEqual(items[0].state, .on)
        XCTAssertEqual(items[2].title, "Work · Session")
        XCTAssertEqual(items[2].state, .off)
        XCTAssertEqual(items[2].representedObject as? String, "claude:1")
        XCTAssertEqual(items[4].title, "All Providers")
        XCTAssertEqual(items[4].state, .off)
    }

    func testMenuBarShowsSubmenuChecksThePinnedWindowInsteadOfAuto() {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            menuBarShows: StatusMenuBuilder.MenuBarShowsSnapshot(
                mode: .merged,
                pinnedKey: "claude:1",
                options: [StatusItemPinOption(id: "claude:1", title: "Work · Session")]
            ),
            status: StatusMenuBuilder.StatusSnapshot()
        )

        let items = builder.makeMenuBarShowsMenu().items

        XCTAssertEqual(items[0].state, .off)
        XCTAssertEqual(items[2].state, .on)
    }

    func testMenuBarShowsSubmenuChecksAllProvidersInPerProviderMode() {
        let builder = StatusMenuBuilder(
            target: nil,
            actions: Self.actions,
            showInDock: true,
            menuBarShows: StatusMenuBuilder.MenuBarShowsSnapshot(mode: .perProvider),
            status: StatusMenuBuilder.StatusSnapshot()
        )

        let items = builder.makeMenuBarShowsMenu().items

        // No pinnable windows, so the separator between Auto and All collapses.
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].state, .off)
        XCTAssertEqual(items[2].title, "All Providers")
        XCTAssertEqual(items[2].state, .on)
    }

    // MARK: - StatusItemPresenter

    func testAttentionToolTipAppendsToTheExistingTipOrTheDefault() {
        XCTAssertEqual(
            StatusItemPresenter.attentionToolTip(base: "MeterBar: Work"),
            "MeterBar: Work · Provider data needs attention"
        )
        XCTAssertEqual(
            StatusItemPresenter.attentionToolTip(base: nil),
            "MeterBar · Provider data needs attention"
        )
    }

    // MARK: - UsageNotificationCoordinator

    func testFlatNotificationServicesExcludeTheAccountAwareProviders() {
        let services = UsageNotificationCoordinator.flatNotificationServices

        XCTAssertFalse(services.contains(.claudeCode))
        XCTAssertFalse(services.contains(.codexCli))
        XCTAssertEqual(services.count, ServiceType.allCases.count - 2)
    }

    func testAccountNotificationIdentityMapsBothAccountTypes() {
        let claudeID = UUID()
        let claude = ClaudeCodeAccount(
            id: claudeID,
            name: "Claude Work",
            configDirectory: "/tmp/claude",
            isEnabled: false
        )
        XCTAssertEqual(
            AccountNotificationIdentity(account: claude),
            AccountNotificationIdentity(id: claudeID, name: "Claude Work", isEnabled: false)
        )

        let codexID = UUID()
        let codex = CodexAccount(id: codexID, name: "Codex Work", homeDirectory: "/tmp/codex")
        XCTAssertEqual(
            AccountNotificationIdentity(account: codex),
            AccountNotificationIdentity(id: codexID, name: "Codex Work", isEnabled: true)
        )
    }

    // MARK: - Fixtures

    private static func report(
        indicator: ProviderStatusIndicator,
        description: String?,
        components: [ProviderStatusComponent] = []
    ) -> ProviderStatusReport {
        ProviderStatusReport(
            service: .claudeCode,
            pageName: "Anthropic Status",
            pageURL: URL(fileURLWithPath: "/dev/null"),
            summary: ProviderStatusSummary(
                indicator: indicator,
                description: description,
                updatedAt: referenceDate
            ),
            components: components,
            fetchedAt: referenceDate
        )
    }
}
