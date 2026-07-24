import XCTest
import MeterBarShared
@testable import MeterBar

final class UsageMetricsTests: XCTestCase {
    // MARK: - Initialization Tests

    func testInitializationWithAllLimits() {
        let session = UsageLimit(used: 50, total: 100, resetTime: nil)
        let weekly = UsageLimit(used: 200, total: 500, resetTime: nil)
        let codeReview = UsageLimit(used: 10, total: 50, resetTime: nil)

        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: codeReview
        )

        XCTAssertEqual(metrics.service, .claudeCode)
        XCTAssertNotNil(metrics.sessionLimit)
        XCTAssertNotNil(metrics.weeklyLimit)
        XCTAssertNotNil(metrics.codeReviewLimit)
    }

    func testInitializationWithNoLimits() {
        let metrics = UsageMetrics(service: .cursor)

        XCTAssertEqual(metrics.service, .cursor)
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertNil(metrics.codeReviewLimit)
    }

    func testIdIsUnique() {
        let metrics1 = UsageMetrics(service: .claudeCode)
        let metrics2 = UsageMetrics(service: .claudeCode)

        XCTAssertNotEqual(metrics1.id, metrics2.id)
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let original = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 50, total: 100, resetTime: Date()),
            weeklyLimit: UsageLimit(used: 200, total: 500, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
            modelLimitLabel: "Fable"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(UsageMetrics.self, from: encoded)

        XCTAssertEqual(decoded.service, original.service)
        XCTAssertEqual(decoded.sessionLimit?.used, original.sessionLimit?.used)
        XCTAssertEqual(decoded.weeklyLimit?.total, original.weeklyLimit?.total)
        XCTAssertEqual(decoded.modelLimitLabel, "Fable")
    }

    func testLegacyCacheWithoutModelLimitLabelStillDecodes() throws {
        let json = #"""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "service": "Claude Code",
          "lastUpdated": 0
        }
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let decoded = try JSONDecoder().decode(UsageMetrics.self, from: data)

        XCTAssertEqual(decoded.service, .claudeCode)
        XCTAssertNil(decoded.modelLimitLabel)
    }

    func testOverallStatusIgnoresModelScopedExhaustion() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 16, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 71, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
            modelLimitLabel: "Sonnet"
        )

        guard case .good = metrics.overallStatus else {
            return XCTFail("Model-only exhaustion must not mark the provider critical.")
        }
    }

    func testOverallStatusStillReflectsProviderWideExhaustion() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 71, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 0, total: 100, resetTime: nil)
        )

        guard case .critical = metrics.overallStatus else {
            return XCTFail("Session exhaustion must keep the provider critical.")
        }
    }

    func testOverallStatusAlsoKeepsCodexCodeReviewScoped() {
        let metrics = UsageMetrics(
            service: .codexCli,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 100, total: 100, resetTime: nil)
        )

        guard case .good = metrics.overallStatus else {
            return XCTFail("Code Review exhaustion must stay scoped to Code Review.")
        }
    }
}
