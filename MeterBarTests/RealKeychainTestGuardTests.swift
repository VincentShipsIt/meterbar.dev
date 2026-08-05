import Foundation
import Security
import XCTest
@testable import MeterBar

/// The debug-build seal that keeps issue #319's silent keychain hang extinct:
/// a unit-test process without the live-integration opt-in sees an empty real
/// login keychain (reads short-circuit to not-found — deterministic and
/// prompt-free on every machine) and may never write to it. The decision is
/// pure and injectable; these tests pin the whole matrix.
final class RealKeychainTestGuardTests: XCTestCase {
    // MARK: - Test process, no opt-in

    /// A decrypting read can park a headless run behind a securityd ACL
    /// dialog, and even a harmless one makes test outcomes depend on the
    /// machine's login state — both blocked, simulated as absent.
    func testReadsAreBlockedInATestProcessWithoutTheOptIn() {
        XCTAssertTrue(
            RealKeychainTestGuard.isBlocked(.read, isTestProcess: true, environment: [:])
        )
    }

    /// Writes cannot prompt, but they would pollute the developer's real
    /// login keychain from a unit-test run.
    func testWritesAreBlockedInATestProcessWithoutTheOptIn() {
        XCTAssertTrue(
            RealKeychainTestGuard.isBlocked(.write, isTestProcess: true, environment: [:])
        )
    }

    // MARK: - Opt-in

    func testTruthyOptInUnsealsTheRealKeychain() {
        for raw in ["1", "true", "yes", "on", "TRUE", "  yes  "] {
            let environment = [RealKeychainTestGuard.environmentKey: raw]
            XCTAssertFalse(
                RealKeychainTestGuard.isBlocked(
                    .read,
                    isTestProcess: true,
                    environment: environment
                ),
                "\(raw.debugDescription) should unseal the keychain"
            )
            XCTAssertFalse(
                RealKeychainTestGuard.isBlocked(
                    .write,
                    isTestProcess: true,
                    environment: environment
                ),
                "\(raw.debugDescription) should unseal the keychain"
            )
        }
    }

    func testFalsyOptInValuesKeepTheSealInPlace() {
        for raw in ["0", "false", "no", "off", "", "banana"] {
            XCTAssertTrue(
                RealKeychainTestGuard.isBlocked(
                    .read,
                    isTestProcess: true,
                    environment: [RealKeychainTestGuard.environmentKey: raw]
                ),
                "\(raw.debugDescription) should keep the seal in place"
            )
        }
    }

    // MARK: - Shipping app

    func testNonTestProcessesAreNeverBlocked() {
        XCTAssertFalse(
            RealKeychainTestGuard.isBlocked(.read, isTestProcess: false, environment: [:])
        )
        XCTAssertFalse(
            RealKeychainTestGuard.isBlocked(.write, isTestProcess: false, environment: [:])
        )
    }

    // MARK: - Process detection

    /// This suite runs under XCTest, so the runtime probe must say so — this
    /// is what arms the seal for the whole default `swift test` run.
    func testThisTestProcessIsDetectedAsHostingXCTest() {
        XCTAssertTrue(RealKeychainTestGuard.processHostsXCTest)
    }

    // MARK: - The seal itself

    /// End-to-end through the production backend: in this very (un-opted-in)
    /// test process, a real read must come back not-found without ever
    /// touching the Security framework, whatever this machine's keychain
    /// actually holds.
    func testProductionBackendSimulatesAnEmptyKeychainInThisProcess() throws {
        guard !RealKeychainTestGuard.isOptedIn() else {
            throw XCTSkip("run is opted into live keychain access")
        }
        let backend = SecItemKeychainBackend()
        var result: AnyObject?
        let status = backend.copyMatching(
            query: [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.meterbar.app",
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ],
            result: &result
        )
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertNil(result)
    }
}
