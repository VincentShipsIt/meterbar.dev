import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class SettingsViewSmokeTests: XCTestCase {
    func testStandaloneSettingsBuildsAVisibleSidebarLayout() {
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 620)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 840)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 560)
    }
}
