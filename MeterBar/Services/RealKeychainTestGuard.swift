import Foundation

/// Decides whether a real login-keychain operation is allowed in the current
/// process. In the shipping app it always is. In a unit-test process it is
/// allowed only with the explicit live-integration opt-in — the same
/// `METERBAR_INTEGRATION_TESTS` switch `LiveIntegrationTestGate` uses to
/// un-skip `APIIntegrationTests`.
///
/// Why this exists: a `SecItemCopyMatching` that has to *decrypt* an item can
/// make securityd raise an ACL approval dialog when the calling process (the
/// Apple `xctest` runner) is not in the item's trusted-application list. Under
/// a headless `swift test` nobody can answer it, so the run parks forever at
/// 0% CPU (issue #319). Gating individual known-live tests is necessary but
/// not sufficient — any future test that wanders into a singleton holding a
/// real `SecItemKeychainBackend` reintroduces the hang silently. This guard
/// converts that entire class into an immediate, well-labelled debug-build
/// failure at the exact call site.
///
/// Attribute-only reads stay allowed: keychain item attributes are not
/// encrypted, securityd never prompts for them, and existence probes such as
/// `KeychainManager.hasKey` rely on that. Writes are always blocked in an
/// un-opted-in test process — they cannot prompt, but they would pollute the
/// developer's real login keychain.
///
/// The decision is pure and injectable so it is unit-testable; the enforcing
/// `precondition` lives in `SecItemKeychainBackend`.
nonisolated enum RealKeychainTestGuard {
    /// Launch environment variable that opts a run into live keychain and
    /// provider-API access. Shared with `LiveIntegrationTestGate`.
    static let environmentKey = "METERBAR_INTEGRATION_TESTS"

    enum Operation: Equatable {
        case read(requestsSecretData: Bool)
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
        switch operation {
        case let .read(requestsSecretData):
            return requestsSecretData
        case .write:
            return true
        }
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
