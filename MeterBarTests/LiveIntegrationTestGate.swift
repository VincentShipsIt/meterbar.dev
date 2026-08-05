import Foundation
import XCTest
@testable import MeterBar

/// Opt-in gate for tests that talk to the **real** credential stores and the
/// **real** provider APIs.
///
/// `APIIntegrationTests` is documented as requiring live credentials, but it
/// sat in the default test target with nothing but a `hasAccess` guard in front
/// of it. On a machine actually logged into the Claude Code CLI that guard is
/// `true`, so a plain `swift test` walked into a real `SecItemCopyMatching` on
/// the login keychain. The xctest bundle is not in that item's trusted-app ACL,
/// so securityd raised an approval dialog with no foreground app to answer it
/// and the run parked at 0% CPU forever — no failure, no timeout, no output
/// (issue #319).
///
/// Gating on an explicit environment variable makes the default run
/// machine-independent: logged in or not, credentials present or not, the
/// unattended suite behaves the same. CI never sets it, so nothing changes
/// there; it was already skipping by accident because its runners have no
/// credentials.
///
/// Enable with:
/// ```
/// METERBAR_INTEGRATION_TESTS=1 swift test --filter APIIntegrationTests
/// ```
///
/// `isEnabled(environment:)` is pure and injectable so the gate is unit tested
/// without touching the process environment, mirroring `DemoMode`.
nonisolated enum LiveIntegrationTestGate {
    /// Launch environment variable that opts into live-credential tests.
    /// Owned by `RealKeychainTestGuard` so the skip decision here and the
    /// real-keychain debug guard in the app target can never drift.
    static let environmentKey = RealKeychainTestGuard.environmentKey

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        RealKeychainTestGuard.isOptedIn(environment: environment)
    }

    /// Throws `XCTSkip` unless the opt-in is present. Call from `setUpWithError`
    /// so every test in the class is gated, including ones added later.
    static func skipUnlessEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard !isEnabled(environment: environment) else { return }
        throw XCTSkip(
            """
            Live integration tests are opt-in. These reach the real keychain and \
            the real provider APIs. Re-run with \(environmentKey)=1 to include them.
            """
        )
    }
}
