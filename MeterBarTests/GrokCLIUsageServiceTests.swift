import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class GrokCLIUsageServiceTests: XCTestCase {
    func testBillingFixtureMapsWeeklyUsageResetAndCredits() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "creditUsagePercent": 73.5,
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-08T15:05:27.877598+00:00",
                  "end": "2026-07-15T15:05:27.877598+00:00"
                },
                "onDemandCap": { "val": 50 },
                "onDemandUsed": { "val": 12.25 },
                "prepaidBalance": { "val": 8.5 },
                "isUnifiedBillingUser": true
              },
              "subscription_tier": "SuperGrok Heavy"
            }
            """
        )

        let metrics = GrokCLIUsageService.map(result, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(metrics.service, .grok)
        XCTAssertNil(metrics.sessionLimit)
        XCTAssertEqual(metrics.weeklyLimit?.used, 73.5)
        XCTAssertEqual(metrics.weeklyLimit?.total, 100)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(
            metrics.weeklyLimit?.resetTime,
            FlexibleISO8601.date(from: "2026-07-15T15:05:27.877598+00:00")
        )
        XCTAssertEqual(metrics.extraUsage?.state, .on)
        XCTAssertEqual(metrics.extraUsage?.detail, "$8.50 credits · $12.25 / $50.00 on demand")
    }

    func testZeroCreditFixtureMapsExtraUsageOff() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "creditUsagePercent": 30,
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-08T15:05:27Z",
                  "end": "2026-07-15T15:05:27Z"
                },
                "onDemandCap": { "val": 0 },
                "onDemandUsed": { "val": 0 },
                "prepaidBalance": { "val": 0 },
                "isUnifiedBillingUser": true
              },
              "subscription_tier": "X Premium"
            }
            """
        )

        let metrics = GrokCLIUsageService.map(result)

        XCTAssertEqual(metrics.extraUsage?.state, .off)
        XCTAssertNil(metrics.extraUsage?.detail)
    }

    func testMissingCreditFieldsMapsExtraUsageUnknown() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "creditUsagePercent": 10,
                "billingPeriodStart": "2026-07-08T15:05:27Z",
                "billingPeriodEnd": "2026-07-15T15:05:27Z"
              },
              "subscription_tier": "Free"
            }
            """
        )

        let metrics = GrokCLIUsageService.map(result)

        XCTAssertEqual(metrics.weeklyLimit?.used, 10)
        XCTAssertNotNil(metrics.weeklyLimit?.resetTime)
        XCTAssertEqual(metrics.extraUsage?.state, .unknown)
    }

    func testACPRequestSequenceUsesCachedLoginAndPrivateBillingMethod() throws {
        let requests = GrokBillingRPC.requests(clientVersion: "1.2.3")

        XCTAssertEqual(requests.map(\.id), [1, 2, 3])
        XCTAssertEqual(requests.map(\.method), ["initialize", "authenticate", "_x.ai/billing"])
        XCTAssertEqual(requests[1].stringParameter("methodId"), "cached_token")
        XCTAssertEqual(requests[0].nestedStringParameter("clientInfo", key: "version"), "1.2.3")
    }

    private func decodeResult(_ json: String) throws -> GrokBillingResult {
        try JSONDecoder().decode(GrokBillingResult.self, from: Data(json.utf8))
    }
}
