import MeterBarShared
import XCTest
@testable import MeterBar

/// Live check against the Muse account endpoint. **Opt-in only.** It needs a
/// Muse CLI sign-in on this Mac. Without one, or without Keychain access, it
/// skips. An idle window may omit `subs_usage`, so a successful poll is not
/// required to contain a bar.
///
/// ```
/// METERBAR_INTEGRATION_TESTS=1 swift test --filter MuseCodeLiveTests
/// ```
///
/// Shape only. It prints no token and no response body.
final class MuseCodeLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveIntegrationTestGate.skipUnlessEnabled()
    }

    func testLiveAccountEndpointAnswersWithoutPrintingSecrets() async throws {
        let service = MuseCodeService()
        guard service.hasAccess else {
            throw XCTSkip("No Muse CLI sign-in file on this Mac")
        }

        let metrics: UsageMetrics
        do {
            metrics = try await service.fetchUsageMetrics()
        } catch {
            throw XCTSkip("Muse Code did not answer: \(ServiceSupport.safeErrorMessage(for: error))")
        }

        if service.statusNote == MuseCodeCopy.needsKeychainAccess
            || service.statusNote == MuseCodeCopy.needsConnect
            || service.statusNote == MuseCodeCopy.notSignedIn
            || service.statusNote == MuseCodeCopy.rejectedToken {
            throw XCTSkip("Muse Code sign-in is not readable from this process")
        }

        XCTAssertEqual(metrics.service, .museCode)
        if metrics.hasData {
            for limit in [metrics.sessionLimit, metrics.weeklyLimit].compactMap({ $0 }) {
                XCTAssertGreaterThan(limit.total, 0)
                XCTAssertGreaterThanOrEqual(limit.used, 0)
                XCTAssertLessThanOrEqual(limit.percentage, 100)
            }
        }
    }
}
