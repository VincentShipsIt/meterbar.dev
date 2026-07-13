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
}
