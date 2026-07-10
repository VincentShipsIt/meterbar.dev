import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

/// Hosting smoke tests for the Session Wake surfaces. They confirm the views
/// build and lay out non-trivially for every status the coordinator can report,
/// across both the standalone Settings window and the embedded/dashboard stack
/// (issue #98: "Store and SwiftUI hosting tests cover both standalone Settings
/// and embedded/dashboard surfaces").
@MainActor
final class SessionWakeViewHostingTests: XCTestCase {
    private func host<V: View>(_ view: V, width: CGFloat = 360, height: CGFloat = 320) -> NSHostingView<V> {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }

    // MARK: Every status renders

    func testStatusViewRendersEveryState() {
        let states: [SessionWakeStatus] = [
            .off,
            .idle,
            .armed,
            .scanning,
            .waiting(until: Date(timeIntervalSinceNow: 3_600), blockedCount: 4),
            .quotaUnknown(reason: "Not authenticated"),
            .running(completed: 1, total: 4),
            .stopping,
            .completed,
            .needsAttention("Selected account was removed")
        ]

        for status in states {
            let coordinator = PreviewSessionWakeCoordinator(
                status: status,
                eligibility: SessionWakeEligibility(
                    eligibleCount: 3,
                    skips: [SessionWakeSkip(reason: "dead worktree", count: 1)]
                ),
                lastRun: SessionWakeRunSummary(resumed: 2, skipped: 1, failed: 0, finishedAt: Date())
            )
            let hostingView = host(SessionWakeStatusView(coordinator: coordinator))
            XCTAssertGreaterThan(
                hostingView.fittingSize.height,
                0,
                "Status \(status.label) should lay out."
            )
        }
    }

    func testWatcherControlBuilds() {
        let coordinator = PreviewSessionWakeCoordinator(status: .idle)
        let hostingView = host(SessionWakeWatcherControl(coordinator: coordinator))
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    }

    func testStatusBadgeBuilds() {
        let hostingView = host(SessionWakeStatusBadge(status: .running(completed: 2, total: 5)), width: 160, height: 40)
        XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    }

    // MARK: Popover card visibility

    func testPopoverCardHiddenWhenFeatureDisabled() {
        let suite = "SessionWakeViewHostingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }
        let settings = SessionWakeSettingsStore(userDefaults: defaults ?? .standard)
        let visibility = ProviderVisibilityStore(userDefaults: defaults ?? .standard)

        // Feature off → the card collapses to nothing.
        let card = SessionWakePopoverCard(
            coordinator: PreviewSessionWakeCoordinator(status: .off),
            settings: settings,
            providerVisibility: visibility
        )
        let hostingView = host(card, width: 320, height: 60)
        XCTAssertLessThan(
            hostingView.fittingSize.height,
            10,
            "The popover card should be empty when Session Wake is disabled."
        )
    }

    // MARK: Settings surfaces both build with the Automation pane present

    func testStandaloneSettingsBuildsWithAutomationPane() {
        let hostingView = host(SettingsView(), width: 920, height: 620)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 840)
    }

    func testEmbeddedSettingsBuildsWithAutomationPane() {
        let hostingView = host(SettingsView(embeddedInDashboard: true), width: 920, height: 1_200)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 400)
    }
}
