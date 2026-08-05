import Security
import XCTest
@testable import MeterBar

/// The real gate touches process-global securityd state, so these tests assert
/// the two properties that make that safe: the suppression is in force for the
/// duration of the operation, and the prior state is always put back.
final class KeychainInteractionGateTests: XCTestCase {
    func testSuppressionIsInForceForTheDurationOfTheOperation() throws {
        let gate = LegacyKeychainInteractionGate()
        var observedInside: Bool?

        let status = gate.withUserInteraction(allowed: false) {
            observedInside = LegacyKeychainInteractionGate.currentUserInteractionAllowed()
            return errSecSuccess
        }

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(
            try XCTUnwrap(observedInside),
            false,
            "The keychain operation must run with securityd UI suppressed."
        )
    }

    func testAllowedOperationRunsWithInteractionPermitted() throws {
        let gate = LegacyKeychainInteractionGate()
        var observedInside: Bool?

        _ = gate.withUserInteraction(allowed: true) {
            observedInside = LegacyKeychainInteractionGate.currentUserInteractionAllowed()
            return errSecSuccess
        }

        XCTAssertEqual(try XCTUnwrap(observedInside), true)
    }

    func testPreviousProcessStateIsRestoredAfterwards() throws {
        let gate = LegacyKeychainInteractionGate()
        let before = try XCTUnwrap(LegacyKeychainInteractionGate.currentUserInteractionAllowed())

        _ = gate.withUserInteraction(allowed: !before) { errSecSuccess }

        XCTAssertEqual(LegacyKeychainInteractionGate.currentUserInteractionAllowed(), before)
    }

    func testOperationStatusIsReturnedUnchanged() {
        let gate = LegacyKeychainInteractionGate()

        XCTAssertEqual(
            gate.withUserInteraction(allowed: false) { errSecAuthFailed },
            errSecAuthFailed
        )
    }

    /// The gate serializes on a process-global flag. A recursive lock is the
    /// point: a nested read must not deadlock, and the innermost restore must
    /// not leak out past the outer scope.
    func testNestedUseRestoresEachScopeInTurn() throws {
        let gate = LegacyKeychainInteractionGate()
        let before = try XCTUnwrap(LegacyKeychainInteractionGate.currentUserInteractionAllowed())
        var observedAfterInnerScope: Bool?

        _ = gate.withUserInteraction(allowed: false) {
            _ = gate.withUserInteraction(allowed: true) { errSecSuccess }
            observedAfterInnerScope = LegacyKeychainInteractionGate.currentUserInteractionAllowed()
            return errSecSuccess
        }

        XCTAssertEqual(try XCTUnwrap(observedAfterInnerScope), false)
        XCTAssertEqual(LegacyKeychainInteractionGate.currentUserInteractionAllowed(), before)
    }
}
