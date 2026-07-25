import Foundation
import XCTest
@testable import MeterBar

/// The demo-mode gate must be off by default and only flip on for an explicit
/// opt-in: a truthy `METERBAR_DEMO` launch variable or the hidden prefs toggle.
/// `isEnabled(environment:defaults:)` is injectable so this never touches the
/// real process environment or standard defaults.
final class DemoModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DemoModeTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testOffByDefaultWhenNoOptInIsPresent() {
        XCTAssertFalse(DemoMode.isEnabled(environment: [:], defaults: defaults))
    }

    func testTruthyEnvironmentValuesEnableDemoMode() {
        for raw in ["1", "true", "yes", "on", "TRUE", "On", "  yes  "] {
            XCTAssertTrue(
                DemoMode.isEnabled(environment: [DemoMode.environmentKey: raw], defaults: defaults),
                "\(raw.debugDescription) should enable demo mode"
            )
        }
    }

    func testFalsyEnvironmentValuesDoNotEnableDemoMode() {
        for raw in ["0", "false", "no", "off", "", "banana"] {
            XCTAssertFalse(
                DemoMode.isEnabled(environment: [DemoMode.environmentKey: raw], defaults: defaults),
                "\(raw.debugDescription) should not enable demo mode"
            )
        }
    }

    func testHiddenPreferenceTogglesDemoModeWhenEnvironmentIsAbsent() {
        defaults.set(true, forKey: StorageKeys.demoMode)
        XCTAssertTrue(DemoMode.isEnabled(environment: [:], defaults: defaults))

        defaults.set(false, forKey: StorageKeys.demoMode)
        XCTAssertFalse(DemoMode.isEnabled(environment: [:], defaults: defaults))
    }

    func testTruthyEnvironmentWinsOverAFalsePreference() {
        defaults.set(false, forKey: StorageKeys.demoMode)
        XCTAssertTrue(
            DemoMode.isEnabled(environment: [DemoMode.environmentKey: "1"], defaults: defaults)
        )
    }

    func testFalsyEnvironmentFallsThroughToAnEnabledPreference() {
        defaults.set(true, forKey: StorageKeys.demoMode)
        XCTAssertTrue(
            DemoMode.isEnabled(environment: [DemoMode.environmentKey: "0"], defaults: defaults)
        )
    }
}
