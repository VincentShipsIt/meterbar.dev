import Foundation
import XCTest

/// The live-integration gate must be **off** by default, so a plain `swift test`
/// can never walk into the real login keychain or the network. Only an explicit
/// truthy `METERBAR_INTEGRATION_TESTS` opts in.
///
/// `isEnabled(environment:)` is injectable so these assertions never depend on
/// the environment the suite happens to run under — including a developer shell
/// that already exports the opt-in.
final class LiveIntegrationTestGateTests: XCTestCase {
    func testOffByDefaultWhenTheOptInIsAbsent() {
        XCTAssertFalse(LiveIntegrationTestGate.isEnabled(environment: [:]))
    }

    func testTruthyEnvironmentValuesEnableTheGate() {
        for raw in ["1", "true", "yes", "on", "TRUE", "On", "  yes  "] {
            XCTAssertTrue(
                LiveIntegrationTestGate.isEnabled(
                    environment: [LiveIntegrationTestGate.environmentKey: raw]
                ),
                "\(raw.debugDescription) should enable live integration tests"
            )
        }
    }

    func testFalsyEnvironmentValuesDoNotEnableTheGate() {
        for raw in ["0", "false", "no", "off", "", "banana"] {
            XCTAssertFalse(
                LiveIntegrationTestGate.isEnabled(
                    environment: [LiveIntegrationTestGate.environmentKey: raw]
                ),
                "\(raw.debugDescription) should not enable live integration tests"
            )
        }
    }

    func testUnrelatedEnvironmentKeysDoNotEnableTheGate() {
        XCTAssertFalse(
            LiveIntegrationTestGate.isEnabled(environment: ["METERBAR_DEMO": "1", "CI": "true"])
        )
    }

    func testSkipUnlessEnabledThrowsSkipWhenTheOptInIsAbsent() {
        XCTAssertThrowsError(
            try LiveIntegrationTestGate.skipUnlessEnabled(environment: [:])
        ) { error in
            XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(type(of: error))")
        }
    }

    func testSkipUnlessEnabledDoesNotThrowWhenTheOptInIsPresent() {
        XCTAssertNoThrow(
            try LiveIntegrationTestGate.skipUnlessEnabled(
                environment: [LiveIntegrationTestGate.environmentKey: "1"]
            )
        )
    }
}
