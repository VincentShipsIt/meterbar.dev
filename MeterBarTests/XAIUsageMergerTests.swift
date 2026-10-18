import XCTest
import MeterBarShared
@testable import MeterBar

final class XAIUsageMergerTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 2_000_000_000)

    private func weekly(_ used: Double, label: String? = nil) -> UsageLimit {
        UsageLimit(used: used, total: 100, resetTime: reset, periodKind: .weekly, label: label)
    }

    func testReturnsNilWhenNeitherSourceProducedMetrics() {
        XCTAssertNil(XAIUsageMerger.merge(grok: nil, cursor: nil))
    }

    func testSingleSourcePassesThroughUnchanged() {
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(30))
        XCTAssertEqual(XAIUsageMerger.merge(grok: grok, cursor: nil)?.weeklyLimit?.used, 30)
        XCTAssertEqual(XAIUsageMerger.merge(grok: nil, cursor: grok)?.weeklyLimit?.used, 30)
    }

    func testSharedWeeklyPoolIsDrawnOnceAndGrokWins() {
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(30))
        let cursor = UsageMetrics(service: .xai, weeklyLimit: weekly(35))

        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)

        XCTAssertEqual(merged?.service, .xai)
        XCTAssertEqual(merged?.weeklyLimit?.used, 30)
        XCTAssertTrue(merged?.additionalLimits.isEmpty == true)
    }

    func testCursorFillsWeeklyWhenGrokReportedNothing() {
        let grok = UsageMetrics(service: .xai, extraUsage: ExtraUsageStatus(state: .on, detail: "$10.00 credits"))
        let cursor = UsageMetrics(service: .xai, weeklyLimit: weekly(35))

        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)

        XCTAssertEqual(merged?.weeklyLimit?.used, 35)
        XCTAssertEqual(merged?.extraUsage?.detail, "$10.00 credits")
    }

    func testLegacyCursorPoolsAndOnDemandSurviveBesideGrokWeekly() {
        let models = UsageLimit(
            used: 20, total: 100, resetTime: reset, periodKind: .monthly,
            label: ServiceType.legacyCursorModelsLabel
        )
        let other = UsageLimit(
            used: 5, total: 100, resetTime: reset, periodKind: .monthly,
            label: ServiceType.legacyOtherModelsLabel
        )
        let onDemand = UsageLimit(used: 3, total: 10, resetTime: reset)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(30), resetCreditsAvailable: 2)
        let cursor = UsageMetrics(
            service: .xai,
            codeReviewLimit: onDemand,
            additionalLimits: [models, other]
        )

        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)

        XCTAssertEqual(merged?.weeklyLimit?.used, 30)
        XCTAssertEqual(merged?.codeReviewLimit, onDemand)
        XCTAssertEqual(merged?.additionalLimits, [models, other])
        XCTAssertEqual(merged?.resetCreditsAvailable, 2)
    }

    func testDuplicateAdditionalLimitsCollapse() {
        let extra = weekly(10, label: "Reserve")
        let grok = UsageMetrics(service: .xai, additionalLimits: [extra])
        let cursor = UsageMetrics(service: .xai, additionalLimits: [extra])

        XCTAssertEqual(XAIUsageMerger.merge(grok: grok, cursor: cursor)?.additionalLimits, [extra])
    }

    func testNewestTimestampWins() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(1), lastUpdated: older)
        let cursor = UsageMetrics(service: .xai, weeklyLimit: weekly(2), lastUpdated: newer)

        XCTAssertEqual(XAIUsageMerger.merge(grok: grok, cursor: cursor)?.lastUpdated, newer)
    }

    // MARK: - Legacy cache migration

    func testLegacyRawValuesDecodeToXAI() throws {
        for raw in ["Grok", "Cursor", "xAI"] {
            let decoded = try JSONDecoder().decode(ServiceType.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(decoded, .xai, raw)
        }
        XCTAssertNil(ServiceType(rawValue: "Claude"))
        XCTAssertEqual(ServiceType.xai.rawValue, "xAI")
    }

    func testMetricsCodecFoldsLegacyGrokAndCursorEntries() throws {
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(30))
        let cursor = UsageMetrics(
            service: .xai,
            codeReviewLimit: UsageLimit(used: 3, total: 10, resetTime: reset)
        )
        let encoder = JSONEncoder()
        let json: [String: Any] = [
            "Grok": try JSONSerialization.jsonObject(with: encoder.encode(grok)),
            "Cursor": try JSONSerialization.jsonObject(with: encoder.encode(cursor))
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = MetricsCodec.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[.xai]?.weeklyLimit?.used, 30)
        XCTAssertEqual(decoded[.xai]?.codeReviewLimit?.used, 3)
    }

    func testLoneMonthlyCursorQuotaSurvivesBesideGrokWeekly() {
        let monthly = UsageLimit(used: 40, total: 500, resetTime: reset, periodKind: .monthly)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(30))
        let cursor = UsageMetrics(service: .xai, weeklyLimit: monthly)

        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)

        XCTAssertEqual(merged?.weeklyLimit?.used, 30)
        XCTAssertEqual(merged?.additionalLimits, [monthly])
    }
}
