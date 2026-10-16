import MeterBarShared
import XCTest
@testable import MeterBar

final class ClaudePlatformReadinessTests: XCTestCase {
    private func check(_ report: ProviderReadiness, _ id: String) -> ReadinessCheck? {
        report.checks.first { $0.id == id }
    }

    func testMissingSessionFailsAuthWithAPasteRecovery() {
        let report = ProviderReadinessEvaluator.claudePlatform(ClaudePlatformReadinessInput(hasSessionKey: false))
        XCTAssertEqual(report.provider, .claudePlatform)
        XCTAssertEqual(check(report, ReadinessCheckID.auth)?.level, .fail)
        XCTAssertNotNil(check(report, ReadinessCheckID.auth)?.recovery)
        XCTAssertEqual(check(report, ReadinessCheckID.data)?.level, .warn)
    }

    func testSessionWithoutAClassificationAsksForARefresh() {
        let report = ProviderReadinessEvaluator.claudePlatform(ClaudePlatformReadinessInput(hasSessionKey: true))
        XCTAssertEqual(check(report, ReadinessCheckID.auth)?.level, .pass)
        XCTAssertEqual(check(report, ReadinessCheckID.data)?.level, .warn)
        XCTAssertTrue(check(report, ReadinessCheckID.data)?.recovery?.contains("meterbar refresh") == true)
    }

    func testReadableAccountPasses() {
        let report = ProviderReadinessEvaluator.claudePlatform(
            ClaudePlatformReadinessInput(hasSessionKey: true, support: .readable)
        )
        XCTAssertEqual(check(report, ReadinessCheckID.data)?.level, .pass)
    }

    func testUnsupportedShapesAreWarningsWithAnAuthoredReason() {
        for support in [ClaudePlatformAccountSupport.noAPIOrganization, .billingAccessDenied] {
            let report = ProviderReadinessEvaluator.claudePlatform(
                ClaudePlatformReadinessInput(hasSessionKey: true, support: support)
            )
            let data = check(report, ReadinessCheckID.data)
            XCTAssertEqual(data?.level, .warn, support.rawValue)
            XCTAssertEqual(data?.detail, support.message)
        }
    }

    func testReportNeverCarriesSecretsOrProviderText() {
        let report = ProviderReadinessEvaluator.claudePlatform(
            ClaudePlatformReadinessInput(hasSessionKey: true, support: .readable, refreshError: "HTTP 429")
        )
        let text = report.checks.map { "\($0.title) \($0.detail) \($0.recovery ?? "")" }.joined()
        XCTAssertFalse(text.contains("sk-ant"))
    }

    func testInspectorReportReadsInjectedState() {
        let report = ProviderReadinessInspector.claudePlatformReport(
            refreshError: nil,
            hasSessionKey: { true },
            support: { .billingAccessDenied }
        )
        XCTAssertEqual(report.provider, .claudePlatform)
        XCTAssertEqual(check(report, ReadinessCheckID.data)?.detail, ClaudePlatformAccountSupport.billingAccessDenied.message)
    }

    func testSupportTokensAreStable() {
        XCTAssertEqual(ClaudePlatformAccountSupport.readable.rawValue, "readable")
        XCTAssertEqual(ClaudePlatformAccountSupport.noAPIOrganization.rawValue, "noAPIOrganization")
        XCTAssertEqual(ClaudePlatformAccountSupport.billingAccessDenied.rawValue, "billingAccessDenied")
    }
}
