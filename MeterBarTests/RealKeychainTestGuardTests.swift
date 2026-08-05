import Foundation
import XCTest
@testable import MeterBar

/// The debug-build guard that turns issue #319's silent keychain hang into a
/// loud failure: a unit-test process may never ask the real login keychain to
/// decrypt an item, or write to it, unless the live-integration opt-in is set.
/// The decision is pure and injectable; these tests pin the whole matrix.
final class RealKeychainTestGuardTests: XCTestCase {
    // MARK: - Test process, no opt-in

    func testSecretDataReadsAreBlockedInATestProcessWithoutTheOptIn() {
        XCTAssertTrue(
            RealKeychainTestGuard.isBlocked(
                .read(requestsSecretData: true),
                isTestProcess: true,
                environment: [:]
            )
        )
    }

    /// Attribute reads never decrypt and never prompt; existence probes such
    /// as `KeychainManager.hasKey` depend on them staying allowed.
    func testAttributeOnlyReadsStayAllowedSoExistenceProbesKeepWorking() {
        XCTAssertFalse(
            RealKeychainTestGuard.isBlocked(
                .read(requestsSecretData: false),
                isTestProcess: true,
                environment: [:]
            )
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

    func testTruthyOptInDisarmsTheGuard() {
        for raw in ["1", "true", "yes", "on", "TRUE", "  yes  "] {
            let environment = [RealKeychainTestGuard.environmentKey: raw]
            XCTAssertFalse(
                RealKeychainTestGuard.isBlocked(
                    .read(requestsSecretData: true),
                    isTestProcess: true,
                    environment: environment
                ),
                "\(raw.debugDescription) should disarm the guard"
            )
            XCTAssertFalse(
                RealKeychainTestGuard.isBlocked(
                    .write,
                    isTestProcess: true,
                    environment: environment
                ),
                "\(raw.debugDescription) should disarm the guard"
            )
        }
    }

    func testFalsyOptInValuesKeepTheGuardArmed() {
        for raw in ["0", "false", "no", "off", "", "banana"] {
            XCTAssertTrue(
                RealKeychainTestGuard.isBlocked(
                    .read(requestsSecretData: true),
                    isTestProcess: true,
                    environment: [RealKeychainTestGuard.environmentKey: raw]
                ),
                "\(raw.debugDescription) should keep the guard armed"
            )
        }
    }

    // MARK: - Shipping app

    func testNonTestProcessesAreNeverBlocked() {
        XCTAssertFalse(
            RealKeychainTestGuard.isBlocked(
                .read(requestsSecretData: true),
                isTestProcess: false,
                environment: [:]
            )
        )
        XCTAssertFalse(
            RealKeychainTestGuard.isBlocked(.write, isTestProcess: false, environment: [:])
        )
    }

    // MARK: - Process detection

    /// This suite runs under XCTest, so the runtime probe must say so — this
    /// is what arms the guard for the whole default `swift test` run.
    func testThisTestProcessIsDetectedAsHostingXCTest() {
        XCTAssertTrue(RealKeychainTestGuard.processHostsXCTest)
    }
}
