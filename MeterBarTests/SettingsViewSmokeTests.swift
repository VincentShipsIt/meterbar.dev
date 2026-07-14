import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class SettingsViewSmokeTests: XCTestCase {
    func testStandaloneSettingsBuildsACompactTabbedLayout() {
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
        hostingView.layoutSubtreeIfNeeded()

        // Compact, MacSweep-style: a fixed 760x660 tabbed window, not a wide sidebar.
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 720)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, 820)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 560)
    }

    func testProviderNotConnectedEmptyStateRendersInSettingsSection() {
        // Mirrors the real composition: the unified EmptyStateCard nested inside
        // a SettingsPanelSection tile, at the settings column width. Guards that
        // the migrated not-connected notices lay out where the old stacked
        // SettingsNotices used to.
        let section = SettingsPanelSection(
            title: "Cursor",
            systemImage: "person.crop.circle",
            color: MeterBarTheme.cursorAccent
        ) {
            EmptyStateCard(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Not connected",
                message: "Log in to Cursor IDE, then Check Again.",
                tone: .warning
            )
        }

        let hostingView = NSHostingView(rootView: section.frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
