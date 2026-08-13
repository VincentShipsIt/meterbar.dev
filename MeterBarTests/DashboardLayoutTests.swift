import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Layout-audit coverage: sidebar grouping, header-hosted card controls,
/// and the paired cost headline cards.
@MainActor
final class DashboardLayoutTests: XCTestCase {
    // MARK: - Sidebar groups

    func testSidebarGroupsCoverEveryDashboardSection() {
        let flattened = DashboardSection.sidebarGroups.flatMap(\.sections)

        XCTAssertEqual(Set(flattened).count, flattened.count, "sidebar must not repeat a section")
        XCTAssertEqual(
            Set(flattened),
            Set(DashboardSection.allCases),
            "every dashboard section must stay reachable from the sidebar"
        )
    }

    func testSidebarGroupOrderLeadsWithMonitoringPages() {
        let groups = DashboardSection.sidebarGroups

        XCTAssertEqual(groups.first?.sections.first, .overview)
        XCTAssertEqual(groups.first?.sections, [.overview, .limits, .costs, .optimize])
        XCTAssertTrue(
            groups.contains { $0.sections == [.status, .diagnostics] },
            "health pages group together"
        )
    }

    // MARK: - DashboardCard trailing view slot

    func testDashboardCardAcceptsTrailingControl() {
        let card = DashboardCard(title: "Token Burn") {
            Picker("Window", selection: .constant(30)) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
        } content: {
            Text("chart")
        }

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testDashboardCardStringTrailingStillBuilds() {
        let card = DashboardCard(title: "Daily Details", trailing: "Last 30 days") {
            Text("rows")
        }

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    // MARK: - Cost headline cards

    func testLoadedCostOverviewCardStaysCompact() {
        let start = Date(timeIntervalSince1970: 1_765_324_800)
        let end = Date(timeIntervalSince1970: 1_786_003_200)
        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: 1_000,
            outputTokens: 200,
            cacheCreationTokens: 0,
            cacheReadTokens: 500,
            estimatedCostUSD: 5_015.59,
            sessionCount: 1,
            periodStart: start,
            periodEnd: end
        )
        let summary = CostSummary(
            costs: [cost],
            totalCostUSD: cost.estimatedCostUSD,
            totalTokens: cost.totalTokens,
            periodDays: 30
        )
        let overview = CostOverviewStatusCard(
            summary: summary,
            isScanning: false,
            isRefreshingMissingDays: false,
            formattedTokens: UsageFormat.tokens(summary.totalTokens)
        )

        let overviewHost = NSHostingView(rootView: overview.frame(width: 380))
        overviewHost.layoutSubtreeIfNeeded()

        XCTAssertLessThan(overviewHost.fittingSize.height, 220)
    }

    func testScanScopeBannerBuildsWithALargeCorpusWarning() {
        var progress = CostScanProgress(windowDays: 30)
        progress.listedFiles = 80
        progress.listedBytes = CostScanProgress.largeCorpusBytes
        progress.processedFiles = 10

        let banner = CostScanScopeBanner(progress: progress)
        let host = NSHostingView(rootView: banner.frame(width: 760))
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(progress.isLargeCorpus)
    }

    // MARK: - Provider card context-menu commands

    private func makeSnapshot(
        title: String = "Codex",
        service: ServiceType = .codexCli
    ) -> ProviderSnapshot {
        ProviderSnapshotBuilder.snapshot(
            title: title,
            service: service,
            metrics: nil,
            emptyDetail: ""
        )
    }

    func testProviderCardCommandsExposeExpectedItemsInOrder() {
        let commands = ProviderCardCommands.make(
            snapshot: makeSnapshot(),
            refresh: { _ in },
            openStatusPage: { _ in },
            hide: { _ in },
            openInDashboard: {}
        )

        XCTAssertEqual(
            commands.map(\.id),
            [.refresh, .openStatusPage, .openInDashboard, .hide],
            "context menu mirrors then extends the hidden status menu in a stable order"
        )
        XCTAssertEqual(
            commands.map(\.title),
            ["Refresh this provider", "Open status page", "Open in Dashboard", "Hide provider"]
        )
        XCTAssertEqual(
            commands.first { $0.id == .hide }?.isDestructive,
            true,
            "hiding a provider is the destructive action"
        )
    }

    func testProviderCardCommandsFireTheirWiredActions() {
        var refreshed: [ServiceType] = []
        var statusOpened: [ServiceType] = []
        var hidden: [ServiceType] = []
        var dashboardOpens = 0

        let commands = ProviderCardCommands.make(
            snapshot: makeSnapshot(title: "Cursor", service: .cursor),
            refresh: { refreshed.append($0) },
            openStatusPage: { statusOpened.append($0) },
            hide: { hidden.append($0) },
            openInDashboard: { dashboardOpens += 1 }
        )

        // "Fire" every menu item and assert each side effect ran with the card's
        // own service — the whole point of the context menu.
        commands.forEach { $0.action() }

        XCTAssertEqual(refreshed, [.cursor])
        XCTAssertEqual(statusOpened, [.cursor])
        XCTAssertEqual(hidden, [.cursor])
        XCTAssertEqual(dashboardOpens, 1)
    }

    func testStandardProviderCardCommandsCoverEveryKind() {
        let commands = ProviderCardCommands.standard(snapshot: makeSnapshot(title: "Claude", service: .claudeCode))

        XCTAssertEqual(
            Set(commands.map(\.id)),
            Set(ProviderCardCommand.Kind.allCases),
            "production wiring must offer every command kind"
        )
    }

    // MARK: - Refresh keyboard shortcut

    func testRefreshShortcutIsCommandR() {
        XCTAssertEqual(MeterBarShortcut.refreshKey.character, "r")
        XCTAssertEqual(MeterBarShortcut.refreshModifiers, .command)
    }

    // MARK: - Card hosts with the affordances attached

    func testProviderOverviewCardHostsWithChevronAndContextMenu() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: MetricsFixtures.codexCli(),
            emptyDetail: ""
        )
        // Tappable card: hover style, chevron, and context menu are all attached.
        let card = ProviderStatusCard(snapshot: snapshot) {}

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
