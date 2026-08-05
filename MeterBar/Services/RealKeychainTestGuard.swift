import Foundation

/// Decides how a real login-keychain operation behaves in the current
/// process. In the shipping app: untouched. In a unit-test process without
/// the explicit live-integration opt-in — the same `METERBAR_INTEGRATION_TESTS`
/// switch `LiveIntegrationTestGate` uses to un-skip `APIIntegrationTests` —
/// the real keychain is hermetically sealed off:
///
/// - **Reads behave as if the keychain were empty** (`errSecItemNotFound`,
///   short-circuited before Security is ever called). A decrypting
///   `SecItemCopyMatching` can make securityd raise an ACL approval dialog
///   when the calling process (Apple's `xctest` runner) is not in the item's
///   trusted-application list; under a headless `swift test` nobody can
///   answer it and the run parks forever at 0% CPU (issue #319). Simulating
///   absence also makes the default run machine-independent: logged in or
///   not, credentials present or not, every unit test sees the same world —
///   which is exactly what CI runners (no items) already showed.
/// - **Writes fail loudly** (debug-build `precondition`): they cannot prompt,
///   but they would pollute the developer's real login keychain, and a write
///   from a unit test is always a test bug worth a stack trace.
///
/// Gating individual known-live tests is necessary but not sufficient — app
/// singletons (`ClaudeCodeLocalService.checkAccess()`, the auto-refresh
/// timer) probe credentials from background tasks whenever a test touches
/// them, and which branch they take depends on machine state. Sealing the
/// backend severs that whole class at the funnel.
///
/// The decision is pure and injectable so it is unit-testable; the enforcing
/// code lives in `SecItemKeychainBackend`.
nonisolated enum RealKeychainTestGuard {
    /// Launch environment variable that opts a run into live keychain and
    /// provider-API access. Shared with `LiveIntegrationTestGate`.
    static let environmentKey = "METERBAR_INTEGRATION_TESTS"

    enum Operation: Equatable {
        case read
        case write
    }

    /// True when XCTest is loaded into this process — i.e. this is a test
    /// runner, not the shipping app. Resolved via the runtime so the app
    /// target never links XCTest.
    static let processHostsXCTest = NSClassFromString("XCTestCase") != nil

    static func isBlocked(
        _ operation: Operation,
        isTestProcess: Bool = processHostsXCTest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isTestProcess, !isOptedIn(environment: environment) else { return false }
        // Both operations are blocked; they differ only in consequence at the
        // backend (reads simulate absence, writes trap).
        _ = operation
        return true
    }

    /// Truthy parse of the opt-in, shared by this guard and the test target's
    /// `LiveIntegrationTestGate` so the two can never drift.
    static func isOptedIn(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[environmentKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
