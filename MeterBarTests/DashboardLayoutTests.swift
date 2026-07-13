import AppKit
@testable import MeterBar
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
}
