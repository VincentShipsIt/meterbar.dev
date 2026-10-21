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

    func testNewerEmptySourceCannotRefreshOlderQuota() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(1), lastUpdated: older)
        let cursor = UsageMetrics(service: .xai, lastUpdated: newer)

        XCTAssertEqual(XAIUsageMerger.merge(grok: grok, cursor: cursor)?.lastUpdated, older)
    }

    func testFreshSharedCursorPoolReplacesStaleGrokWeekly() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let grok = UsageMetrics(
            service: .xai, weeklyLimit: weekly(100), lastUpdated: now.addingTimeInterval(-10_800)
        )
        let cursor = UsageMetrics(service: .xai, weeklyLimit: weekly(20), lastUpdated: now)
        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)
        XCTAssertEqual(merged?.weeklyLimit?.used, 20)
        XCTAssertEqual(merged?.lastUpdated, now)
        XCTAssertTrue(merged?.additionalLimits.isEmpty == true)
    }

    func testRetainedOldSessionKeepsMergedSnapshotStale() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 10_000)
        let grok = UsageMetrics(
            service: .xai, sessionLimit: weekly(80), lastUpdated: older
        )
        let cursor = UsageMetrics(service: .xai, weeklyLimit: weekly(20), lastUpdated: newer)
        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)
        XCTAssertEqual(merged?.sessionLimit?.used, 80)
        XCTAssertEqual(merged?.weeklyLimit?.used, 20)
        XCTAssertEqual(merged?.lastUpdated, older)
        let decision = WorkloadRouter.route(
            policy: RoutingPolicyDefaults.policy(for: .implementation),
            candidates: [RoutingCandidate(service: .xai, metrics: merged)], now: newer
        )
        XCTAssertNil(decision.recommendation)
        XCTAssertEqual(decision.rejected.first?.code, .snapshotStale)
    }

    func testNewerLegacyMonthlyPoolCannotReplaceSharedWeekly() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 10_000)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(100), lastUpdated: older)
        let monthly = UsageLimit(used: 20, total: 100, resetTime: reset, periodKind: .monthly)
        let cursor = UsageMetrics(service: .xai, weeklyLimit: monthly, lastUpdated: newer)
        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)
        XCTAssertEqual(merged?.weeklyLimit?.used, 100)
        XCTAssertEqual(merged?.additionalLimits, [monthly])
        XCTAssertEqual(merged?.lastUpdated, older)
    }

    func testSharedWeeklyAuthorityChangesOnlyBeyondTheFreshnessWindow() {
        let older = Date(timeIntervalSince1970: 1_000)
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(80), lastUpdated: older)
        for (lag, expected): (TimeInterval, Double) in [(7_200, 80), (7_201, 20)] {
            let cursor = UsageMetrics(
                service: .xai, weeklyLimit: weekly(20), lastUpdated: older.addingTimeInterval(lag)
            )
            XCTAssertEqual(XAIUsageMerger.merge(grok: grok, cursor: cursor)?.weeklyLimit?.used, expected)
        }
    }

    func testOldOptionalAllowanceCannotAcquireFreshWeeklyTimestamp() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 10_000)
        let allowance = weekly(40, label: "Reserve")
        let grok = UsageMetrics(service: .xai, weeklyLimit: weekly(20), lastUpdated: newer)
        let cursor = UsageMetrics(service: .xai, additionalLimits: [allowance], lastUpdated: older)
        let merged = XAIUsageMerger.merge(grok: grok, cursor: cursor)
        XCTAssertEqual(merged?.weeklyLimit?.used, 20)
        XCTAssertEqual(merged?.additionalLimits, [allowance])
        XCTAssertEqual(merged?.lastUpdated, older)
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
