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
