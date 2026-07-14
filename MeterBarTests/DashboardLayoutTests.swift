import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Layout-audit coverage: sidebar grouping, header-hosted card controls,
/// and content-hugging cost card.
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

    // MARK: - Cost overview card hugs content

    func testCostOverviewCardHasNoArtificialMinHeight() {
        let card = CostOverviewStatusCard(
            summary: nil,
            isScanning: false,
            isRefreshingMissingDays: false,
            formattedTokens: "0"
        )

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            hostingView.fittingSize.height,
            overviewTileMinHeight,
            "costs-page card should hug its content instead of padding to the overview grid height"
        )
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
        let card = ProviderOverviewStatusCard(snapshot: snapshot) {}

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
