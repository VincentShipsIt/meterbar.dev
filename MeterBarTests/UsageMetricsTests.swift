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

    // MARK: - hasData Tests

    func testHasDataWithSessionLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
        )
        XCTAssertTrue(metrics.hasData)
    }

    func testHasDataWithWeeklyLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            weeklyLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
        )
        XCTAssertTrue(metrics.hasData)
    }

    func testHasDataWithCodeReviewLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            codeReviewLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
        )
        XCTAssertTrue(metrics.hasData)
    }

    func testHasDataWithNoLimits() {
        let metrics = UsageMetrics(service: .cursor)
        XCTAssertFalse(metrics.hasData)
    }

    // MARK: - overallStatus Tests

    func testOverallStatusGoodWhenAllLimitsLow() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
        )
        XCTAssertEqual(metrics.overallStatus, .good)
    }

    func testOverallStatusWarningWhenAnyLimitNearLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 85, total: 100, resetTime: nil) // 85% = near limit
        )
        XCTAssertEqual(metrics.overallStatus, .warning)
    }

    func testOverallStatusCriticalWhenAnyLimitAtLimit() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 100, total: 100, resetTime: nil), // 100% = at limit
            weeklyLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
        )
        XCTAssertEqual(metrics.overallStatus, .critical)
    }

    func testOverallStatusCriticalOverridesWarning() {
        // Even if one limit is at warning, critical should take precedence
        let metrics = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 120, total: 100, resetTime: nil), // Over limit
            weeklyLimit: UsageLimit(used: 85, total: 100, resetTime: nil) // Warning level
        )
        XCTAssertEqual(metrics.overallStatus, .critical)
    }

    func testOverallStatusGoodWhenNoLimits() {
        let metrics = UsageMetrics(service: .cursor)
        XCTAssertEqual(metrics.overallStatus, .good)
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let original = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 50, total: 100, resetTime: Date()),
            weeklyLimit: UsageLimit(used: 200, total: 500, resetTime: nil)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(UsageMetrics.self, from: encoded)

        XCTAssertEqual(decoded.service, original.service)
        XCTAssertEqual(decoded.sessionLimit?.used, original.sessionLimit?.used)
        XCTAssertEqual(decoded.weeklyLimit?.total, original.weeklyLimit?.total)
    }
}
