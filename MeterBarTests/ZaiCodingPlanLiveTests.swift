import MeterBarShared
import XCTest
@testable import MeterBar

/// Live check against Z.ai's real quota endpoint. **Opt-in and key-gated**: it
/// needs `METERBAR_INTEGRATION_TESTS=1` (the same gate as `APIIntegrationTests`)
/// and a Coding Plan key already saved in MeterBar; without either it skips.
///
/// ```
/// METERBAR_INTEGRATION_TESTS=1 swift test --filter ZaiCodingPlanLiveTests
/// ```
///
/// It asserts shape only — never a quota value — and prints no key or body.
final class ZaiCodingPlanLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveIntegrationTestGate.skipUnlessEnabled()
    }

    func testLiveQuotaEndpointParsesIntoAtLeastOneWindow() async throws {
        let service = ZaiCodingPlanService.shared
        guard service.hasAccess else {
            throw XCTSkip("No Z.ai Coding Plan key saved in MeterBar")
        }

        let metrics: UsageMetrics
        do {
            metrics = try await service.fetchUsageMetrics()
        } catch ServiceError.notAuthenticated {
            throw XCTSkip("Z.ai rejected the saved key for the selected region")
        }

        XCTAssertEqual(metrics.service, .zaiCodingPlan)
        XCTAssertTrue(metrics.hasData)
        for limit in [metrics.sessionLimit, metrics.weeklyLimit].compactMap({ $0 }) + metrics.additionalLimits {
            XCTAssertGreaterThan(limit.total, 0)
            XCTAssertGreaterThanOrEqual(limit.used, 0)
        }
    }
}
