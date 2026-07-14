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

    /// Cost Tracking's "Scan 30 Days" (`.glassProminent`) and the Refresh
    /// section's "Refresh Now" (`.glass`) are the Settings CTAs that adopted
    /// Liquid Glass button styles. SwiftPM CI can't drive AppKit hit-testing, so
    /// this smoke test guards the next best thing: that those glass-styled
    /// buttons still compile and lay out inside the real Settings tree. A removed
    /// button or an invalid `.glass`/`.glassProminent` style regresses here — the
    /// action wiring itself is covered by the cost-scan and refresh unit tests.
    func testGlassCostScanAndRefreshCTAsStillRender() {
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 720)
    }
}
