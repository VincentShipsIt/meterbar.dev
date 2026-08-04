import Foundation
import XCTest
@testable import MeterBar

/// Covers the `--launch-smoke` probe the release gate uses to prove a signed
/// bundle actually starts.
///
/// The probe answers before AppKit does, so everything worth testing is pure:
/// which argument vectors request it, and the exact JSON document it emits.
final class LaunchSmokeProbeTests: XCTestCase {
    private static let completeInfo: [String: Any] = [
        "CFBundleIdentifier": "dev.meterbar.app",
        "CFBundleShortVersionString": "1.8.2",
        "CFBundleVersion": "1.8.2"
    ]

    func testFlagIsDetectedAlongsideLaunchServicesArguments() {
        // Launch Services appends its own arguments (`-psn_…`) when the app is
        // opened from Finder; the probe must still be found by exact match.
        XCTAssertTrue(
            LaunchSmokeProbe.isRequested(
                in: ["/Applications/MeterBar.app/Contents/MacOS/MeterBar", "-psn_0_123456", "--launch-smoke"]
            )
        )
    }

    func testProbeIsNotRequestedWithoutTheFlag() {
        XCTAssertFalse(LaunchSmokeProbe.isRequested(in: ["/tmp/MeterBar", "--open-dashboard"]))
    }

    func testProbeRequiresAnExactFlagMatch() {
        // A prefix match would let an unrelated future flag silently short-circuit
        // the real launch.
        XCTAssertFalse(LaunchSmokeProbe.isRequested(in: ["/tmp/MeterBar", "--launch-smoke-please"]))
        XCTAssertFalse(LaunchSmokeProbe.isRequested(in: ["/tmp/MeterBar", "launch-smoke"]))
    }

    func testResponseIsOneVersionedJSONDocumentWithSortedKeys() throws {
        // Byte-exact: the release gate parses this from a process that must not
        // print anything else on stdout.
        XCTAssertEqual(
            try LaunchSmokeProbe.responseJSON(info: Self.completeInfo),
            #"{"buildVersion":"1.8.2","bundleIdentifier":"dev.meterbar.app","#
                + #""launchSmoke":true,"schemaVersion":1,"shortVersion":"1.8.2"}"#
        )
    }

    func testResponseCarriesTheDecoupledNightlyVersionPair() throws {
        var info = Self.completeInfo
        info["CFBundleShortVersionString"] = "1.8.3-nightly.42+a1b2c3d"
        info["CFBundleVersion"] = "1.8.3.42"

        let response = try LaunchSmokeProbe.responseJSON(info: info)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )

        XCTAssertEqual(decoded["shortVersion"] as? String, "1.8.3-nightly.42+a1b2c3d")
        XCTAssertEqual(decoded["buildVersion"] as? String, "1.8.3.42")
        XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
        XCTAssertEqual(decoded["launchSmoke"] as? Bool, true)
    }

    func testResponseFailsWhenBundleMetadataIsIncomplete() throws {
        // A bundle missing its version keys must fail the gate loudly rather than
        // report a launch the release verifier cannot cross-check.
        for missingKey in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"] {
            var info = Self.completeInfo
            info.removeValue(forKey: missingKey)

            XCTAssertThrowsError(try LaunchSmokeProbe.responseJSON(info: info)) { error in
                XCTAssertEqual(
                    error as? LaunchSmokeProbe.ProbeError,
                    .missingBundleMetadata(key: missingKey)
                )
            }
        }
    }

    func testResponseRejectsNonStringBundleMetadata() {
        var info = Self.completeInfo
        info["CFBundleVersion"] = 182

        XCTAssertThrowsError(try LaunchSmokeProbe.responseJSON(info: info)) { error in
            XCTAssertEqual(
                error as? LaunchSmokeProbe.ProbeError,
                .missingBundleMetadata(key: "CFBundleVersion")
            )
        }
    }
}
