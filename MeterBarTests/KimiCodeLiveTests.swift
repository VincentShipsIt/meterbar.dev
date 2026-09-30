import MeterBarShared
import XCTest
@testable import MeterBar

/// Live check against the real Kimi Code usage endpoint. **Opt-in only** — the
/// same gate as `APIIntegrationTests`, because it can reach the real login
/// keychain and the real provider API. It additionally needs a credential:
/// Kimi Code signed in on this Mac, or a Kimi Code API key already saved in
/// MeterBar. Without one it skips rather than fails.
///
/// ```
/// METERBAR_INTEGRATION_TESTS=1 swift test --filter KimiCodeLiveTests
/// ```
///
/// It asserts shape only — never a quota value — and prints no token or body.
final class KimiCodeLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveIntegrationTestGate.skipUnlessEnabled()
    }

    func testLiveUsageEndpointParsesIntoAtLeastOneWindow() async throws {
        let service = KimiCodeService.shared
        guard service.hasAccess else {
            throw XCTSkip("No Kimi Code sign-in or API key available on this Mac")
        }

        let metrics: UsageMetrics
        do {
            metrics = try await service.fetchUsageMetrics()
        } catch ServiceError.notAuthenticated {
            throw XCTSkip("The Kimi Code credential is expired or was rejected; run /login and retry")
        }

        XCTAssertEqual(metrics.service, .kimiCode)
        XCTAssertTrue(metrics.hasData, "a successful poll must map at least one quota window")
        for limit in [metrics.sessionLimit, metrics.weeklyLimit].compactMap({ $0 }) + metrics.additionalLimits {
            XCTAssertGreaterThan(limit.total, 0)
            XCTAssertGreaterThanOrEqual(limit.used, 0)
        }
    }
}
