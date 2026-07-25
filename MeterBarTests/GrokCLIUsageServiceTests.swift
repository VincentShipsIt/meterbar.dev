import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class GrokCLIUsageServiceTests: XCTestCase {
    // MARK: - Mapping

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

        let metrics = try GrokCLIUsageService.map(result, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(metrics.service, .grok)
        // The account-wide percent is a billing-cycle number: it may back-fill the
        // weekly window, but inventing a session window from it would be the
        // fabricated zero this provider is supposed to stop reporting.
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

    func testUsagePeriodsMapOntoSessionAndWeeklyWindowsWithWorkingPace() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "creditUsagePercent": 73.5,
                "usagePeriods": [
                  {
                    "type": "USAGE_PERIOD_TYPE_SESSION",
                    "start": "2026-07-15T12:00:00Z",
                    "end": "2026-07-15T17:00:00Z",
                    "usagePercent": 40
                  },
                  {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-07-08T15:05:27Z",
                    "end": "2026-07-15T15:05:27Z",
                    "usagePercent": 73.5
                  }
                ],
                "onDemandCap": { "val": 50 },
                "onDemandUsed": { "val": 12.25 }
              },
              "subscription_tier": "SuperGrok"
            }
            """
        )

        let now = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-15T14:00:00Z"))
        let metrics = try GrokCLIUsageService.map(result, now: now)

        let session = try XCTUnwrap(metrics.sessionLimit)
        XCTAssertEqual(session.used, 40)
        XCTAssertEqual(session.total, 100)
        XCTAssertEqual(session.windowSeconds, 5 * 60 * 60)
        XCTAssertEqual(session.resetTime, FlexibleISO8601.date(from: "2026-07-15T17:00:00Z"))
        XCTAssertNotNil(session.pace(now: now), "A real session window must resolve pace")

        let weekly = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertEqual(weekly.used, 73.5)
        XCTAssertEqual(weekly.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(weekly.resetTime, FlexibleISO8601.date(from: "2026-07-15T15:05:27Z"))
        XCTAssertNotNil(weekly.pace(now: now), "A real weekly window must resolve pace")
    }

    func testUnknownFieldShapeStillMapsTheUsageItCanRead() throws {
        // Renamed containers, snake_case keys, string-encoded numbers and extra
        // fields MeterBar has never seen: upstream drift must degrade to "read
        // what is readable", not to a decode failure.
        let result = try decodeResult(
            """
            {
              "config": {
                "credit_usage_percent": "61",
                "usage_periods": [
                  {
                    "type": "USAGE_PERIOD_TYPE_5_HOUR",
                    "start_date": "2026-07-15T12:00:00Z",
                    "end_date": "2026-07-15T17:00:00Z",
                    "percent": "22.5",
                    "experimentalBucket": { "unexpected": true }
                  }
                ],
                "on_demand_cap": { "value": 25 },
                "on_demand_used": 5,
                "somethingBrandNew": ["ignored"]
              },
              "subscriptionTier": "SuperGrok",
              "unknownTopLevel": 1
            }
            """
        )

        let now = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-15T14:00:00Z"))
        let metrics = try GrokCLIUsageService.map(result, now: now)

        XCTAssertEqual(result.subscriptionTier, "SuperGrok")
        XCTAssertEqual(metrics.sessionLimit?.used, 22.5)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 60 * 60)
        XCTAssertEqual(metrics.weeklyLimit?.used, 61)
        XCTAssertEqual(metrics.extraUsage?.state, .on)
        XCTAssertEqual(metrics.extraUsage?.detail, "$5.00 / $25.00 on demand")
    }

    func testPeriodWithoutTypeIsClassifiedByItsDuration() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "usagePeriods": [
                  {
                    "start": "2026-07-15T12:00:00Z",
                    "end": "2026-07-15T17:00:00Z",
                    "usagePercent": 12
                  },
                  {
                    "start": "2026-07-08T15:05:27Z",
                    "end": "2026-07-15T15:05:27Z",
                    "usagePercent": 44
                  }
                ]
              }
            }
            """
        )

        let metrics = try GrokCLIUsageService.map(result, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(metrics.sessionLimit?.used, 12)
        XCTAssertEqual(metrics.weeklyLimit?.used, 44)
    }

    func testUsageWithoutAnyReadablePercentIsUnknownRatherThanZero() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "usagePeriods": [
                  {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-07-08T15:05:27Z",
                    "end": "2026-07-15T15:05:27Z"
                  }
                ],
                "onDemandCap": { "val": 50 }
              }
            }
            """
        )

        XCTAssertThrowsError(try GrokCLIUsageService.map(result)) { error in
            XCTAssertEqual(error as? GrokBillingRPC.Error, .invalidResponse)
        }
    }

    func testPercentagesAreClampedIntoRange() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "usagePeriods": [
                  {
                    "type": "USAGE_PERIOD_TYPE_SESSION",
                    "start": "2026-07-15T12:00:00Z",
                    "end": "2026-07-15T17:00:00Z",
                    "usagePercent": -5
                  },
                  {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-07-08T15:05:27Z",
                    "end": "2026-07-15T15:05:27Z",
                    "usagePercent": 145
                  }
                ]
              }
            }
            """
        )

        let metrics = try GrokCLIUsageService.map(result, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(metrics.sessionLimit?.used, 0)
        XCTAssertEqual(metrics.weeklyLimit?.used, 100)
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

        let metrics = try GrokCLIUsageService.map(result)

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

        let metrics = try GrokCLIUsageService.map(result)

        XCTAssertEqual(metrics.weeklyLimit?.used, 10)
        XCTAssertNotNil(metrics.weeklyLimit?.resetTime)
        XCTAssertEqual(metrics.extraUsage?.state, .unknown)
    }

    // MARK: - Transport

    func testACPRequestSequenceUsesCachedLoginAndPrivateBillingMethod() throws {
        let requests = GrokBillingRPC.requests(clientVersion: "1.2.3")

        XCTAssertEqual(requests.map(\.id), [1, 2, 3])
        XCTAssertEqual(requests.map(\.method), ["initialize", "authenticate", "_x.ai/billing"])
        XCTAssertEqual(requests[1].stringParameter("methodId"), "cached_token")
        XCTAssertEqual(requests[0].nestedStringParameter("clientInfo", key: "version"), "1.2.3")
    }

    func testReplayedTranscriptDecodesBillingResult() throws {
        let result = try GrokBillingRPC.result(
            replaying: transcript(
                billing: #"""
                {"jsonrpc":"2.0","id":3,"result":{"config":{"creditUsagePercent":55},"subscription_tier":"SuperGrok"}}
                """#
            )
        )

        XCTAssertEqual(result.subscriptionTier, "SuperGrok")
        XCTAssertEqual(try GrokCLIUsageService.map(result).weeklyLimit?.used, 55)
    }

    func testNoiseAndUnrelatedFramesBeforeBillingAreIgnored() throws {
        let noisy = [
            "Checking for updates…",
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"kind":"log"}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{}}"#,
            "{ not json at all",
            #"{"jsonrpc":"2.0","id":3,"result":{"config":{"creditUsagePercent":12}}}"#
        ]

        let result = try GrokBillingRPC.result(replaying: noisy)

        XCTAssertEqual(try GrokCLIUsageService.map(result).weeklyLimit?.used, 12)
    }

    func testTruncatedResponseIsReportedAsUnparseable() {
        let truncated = transcript(billing: #"{"jsonrpc":"2.0","id":3,"result":{"config":{"creditUsa"#)

        assertReplayFails(with: .invalidResponse, truncated)
    }

    func testBillingResultInAnUnreadableShapeIsReportedAsUnparseable() {
        let wrongShape = transcript(billing: #"{"jsonrpc":"2.0","id":3,"result":"not-an-object"}"#)

        assertReplayFails(with: .invalidResponse, wrongShape)
    }

    func testLoggedOutTranscriptIsReportedAsNotAuthenticated() {
        let loggedOut = [
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"no cached credentials"}}"#
        ]

        assertReplayFails(with: .notAuthenticated, loggedOut)
    }

    func testMethodNotFoundIsReportedAsAnUnsupportedVersion() {
        let tooOld = transcript(
            billing: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}"#
        )

        assertReplayFails(with: .unsupportedVersion, tooOld)
    }

    func testOtherBillingErrorsAreReportedAsAFailedRequest() {
        let refused = transcript(
            billing: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"billing unavailable"}}"#
        )

        assertReplayFails(with: .commandFailed, refused)
    }

    func testAgentThatExitsWithoutAnsweringIsReportedAsAFailedRequest() {
        let silent = [
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        ]

        assertReplayFails(with: .commandFailed, silent)
    }

    // MARK: - Readiness hand-off

    func testTransportFailuresSurviveSanitizationAsActionableHints() {
        let expected: [(GrokBillingRPC.Error, GrokRefreshFailure)] = [
            (.notAuthenticated, .notSignedIn),
            (.invalidResponse, .unparseableResponse),
            (.timedOut, .agentTimedOut),
            (.launchFailed, .agentStartFailed),
            (.unsupportedVersion, .unsupportedVersion),
            (.commandFailed, .requestFailed)
        ]

        for (transportError, failure) in expected {
            let serviceError = GrokCLIUsageService.serviceError(from: transportError)
            let sanitized = ProviderReadinessInspector.sanitize(serviceError)

            XCTAssertEqual(sanitized, failure.message, "\(transportError) lost its hint")
            XCTAssertEqual(
                sanitized.flatMap(GrokRefreshFailure.init(message:)),
                failure,
                "\(transportError) did not round-trip back to a recovery hint"
            )
        }
    }

    func testUnexpectedTransportErrorsStillSanitizeToAGenericMessage() {
        let sanitized = ProviderReadinessInspector.sanitize(
            GrokCLIUsageService.serviceError(from: URLError(.notConnectedToInternet))
        )

        XCTAssertNotNil(sanitized)
        XCTAssertNil(sanitized.flatMap(GrokRefreshFailure.init(message:)))
    }

    // MARK: - Helpers

    private func transcript(billing: String) -> [String] {
        [
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{}}"#,
            billing
        ]
    }

    private func assertReplayFails(
        with expected: GrokBillingRPC.Error,
        _ transcript: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try GrokBillingRPC.result(replaying: transcript), file: file, line: line) { error in
            XCTAssertEqual(error as? GrokBillingRPC.Error, expected, file: file, line: line)
        }
    }

    private func decodeResult(_ json: String) throws -> GrokBillingResult {
        try JSONDecoder().decode(GrokBillingResult.self, from: Data(json.utf8))
    }
}
