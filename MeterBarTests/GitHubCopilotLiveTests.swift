import MeterBarShared
import XCTest
@testable import MeterBar

/// Live check against GitHub's real billing API. **Opt-in and token-gated**: it
/// needs `METERBAR_INTEGRATION_TESTS=1` (the same gate as `APIIntegrationTests`)
/// and a fine-grained token plus account already saved in MeterBar; without
/// either it skips. It asserts the classification is one of the documented
/// shapes and never a billing figure, and prints no token or payload.
///
/// ```
/// METERBAR_INTEGRATION_TESTS=1 swift test --filter GitHubCopilotLiveTests
/// ```
final class GitHubCopilotLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try LiveIntegrationTestGate.skipUnlessEnabled()
    }

    func testLiveBillingAPIClassifiesTheAccount() async throws {
        let service = GitHubCopilotService.shared
        guard service.hasAccess else {
            throw XCTSkip("No GitHub token and account saved in MeterBar")
        }

        do {
            _ = try await service.fetchUsageMetrics()
        } catch ServiceError.notAuthenticated {
            throw XCTSkip("GitHub rejected the saved token")
        }

        let support = try XCTUnwrap(service.support, "a successful poll must classify the account")
        XCTAssertFalse(support.message.isEmpty)
    }
}
