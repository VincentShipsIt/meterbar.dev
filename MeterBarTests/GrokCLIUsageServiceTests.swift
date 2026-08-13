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

    /// Verbatim `_x.ai/billing` config from grok 0.2.112 on an X Premium
    /// account with nothing spent yet. proto3 omits scalar defaults, so
    /// `creditUsagePercent` is absent *because* it is `0.0` — the monetary
    /// submessages survive as `{"val": 0}` only because they are messages.
    /// Reading that omission as unknown is what left Grok stuck on "Failed to
    /// parse response" with a fully working CLI behind it.
    func testCurrentBillingCycleWithoutCreditPercentReadsAsZeroUsage() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_WEEKLY",
                  "start": "2026-07-22T15:05:27.877598+00:00",
                  "end": "2026-07-29T15:05:27.877598+00:00"
                },
                "onDemandCap": { "val": 0 },
                "onDemandUsed": { "val": 0 },
                "prepaidBalance": { "val": 0 },
                "isUnifiedBillingUser": true,
                "billingPeriodStart": "2026-07-22T15:05:27.877598+00:00",
                "billingPeriodEnd": "2026-07-29T15:05:27.877598+00:00"
              },
              "subscription_tier": "X Premium"
            }
            """
        )

        let now = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-24T15:05:27Z"))
        let metrics = try GrokCLIUsageService.map(result, now: now)

        XCTAssertEqual(result.subscriptionTier, "X Premium")
        XCTAssertNil(metrics.sessionLimit, "Grok reports no session window")
        let weekly = try XCTUnwrap(metrics.weeklyLimit)
        XCTAssertEqual(weekly.used, 0)
        XCTAssertEqual(weekly.total, 100)
        XCTAssertEqual(weekly.windowSeconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(
            weekly.resetTime,
            FlexibleISO8601.date(from: "2026-07-29T15:05:27.877598+00:00")
        )
        XCTAssertEqual(metrics.extraUsage?.state, .off)
    }

    /// The same omission with no billing cycle to anchor it stays unknown: an
    /// absent percent only means zero when the response is recognizably a
    /// populated billing config for a dated cycle.
    func testMissingCreditPercentWithoutABillingCycleStaysUnknown() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "onDemandCap": { "val": 0 },
                "isUnifiedBillingUser": true
              }
            }
            """
        )

        XCTAssertThrowsError(try GrokCLIUsageService.map(result)) { error in
            XCTAssertEqual(error as? GrokBillingRPC.Error, .invalidResponse)
        }
    }

    /// A dated cycle inside something that never identified itself as a billing
    /// config, and carries no other billing field, is a foreign shape — not a
    /// zero reading.
    func testDatedPeriodWithoutAnyBillingSignalStaysUnknown() throws {
        let result = try decodeResult(
            """
            {
              "currentPeriod": {
                "start": "2026-07-22T15:05:27Z",
                "end": "2026-07-29T15:05:27Z"
              }
            }
            """
        )

        XCTAssertThrowsError(try GrokCLIUsageService.map(result)) { error in
            XCTAssertEqual(error as? GrokBillingRPC.Error, .invalidResponse)
        }
    }

    /// Credit accounts report the allowance and the spend instead of a percent.
    /// Deriving it matters more than the zero default: falling through to `0`
    /// here would under-report real usage.
    func testCreditAccountDerivesPercentFromAllowanceAndSpend() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "currentPeriod": {
                  "type": "USAGE_PERIOD_TYPE_MONTHLY",
                  "start": "2026-07-01T00:00:00Z",
                  "end": "2026-08-01T00:00:00Z"
                },
                "monthlyLimit": { "val": 200 },
                "usage": {
                  "includedUsed": { "val": 30 },
                  "totalUsed": { "val": 50 }
                },
                "isUnifiedBillingUser": false
              },
              "subscription_tier": "SuperGrok"
            }
            """
        )

        let metrics = try GrokCLIUsageService.map(result)

        XCTAssertEqual(metrics.weeklyLimit?.used, 25, "50 of a 200 allowance is 25%")
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, FlexibleISO8601.date(from: "2026-08-01T00:00:00Z"))
    }

    /// A reported percent stays authoritative even when the credits pair could
    /// also produce one.
    func testReportedCreditPercentWinsOverTheDerivedOne() throws {
        let result = try decodeResult(
            """
            {
              "config": {
                "creditUsagePercent": 61,
                "billingPeriodStart": "2026-07-01T00:00:00Z",
                "billingPeriodEnd": "2026-08-01T00:00:00Z",
                "monthlyLimit": { "val": 200 },
                "usage": { "totalUsed": { "val": 50 } }
              }
            }
            """
        )

        XCTAssertEqual(try GrokCLIUsageService.map(result).weeklyLimit?.used, 61)
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

    func testACPProcessEnvironmentScopesTheOfficialCLIToOneGrokHome() {
        let environment = GrokBillingRPC.processEnvironment(
            grokHome: "/tmp/grok-work",
            base: ["PATH": "/usr/bin", "GROK_HOME": "/tmp/wrong"]
        )

        XCTAssertEqual(environment["GROK_HOME"], "/tmp/grok-work")
        XCTAssertEqual(environment["NO_COLOR"], "1")
        XCTAssertEqual(environment["FORCE_COLOR"], "0")
        XCTAssertEqual(environment["TERM"], "dumb")
    }

    func testAccountFetchUsesOnlyThatProfilesGrokHome() async throws {
        let work = GrokAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/grok-work")
        let defaultResult = try decodeResult(
            #"{"config":{"creditUsagePercent":11},"subscription_tier":"Default"}"#
        )
        let workResult = try decodeResult(
            #"{"config":{"creditUsagePercent":73},"subscription_tier":"Work"}"#
        )
        let service = GrokCLIUsageService(
            binaryPathProvider: { "/usr/local/bin/grok" },
            authAvailableProvider: { _ in true },
            billingResultProvider: { _, grokHome in
                grokHome == "/tmp/grok-work" ? workResult : defaultResult
            },
            authFileDataProvider: { _ in nil },
            remainingResetsProvider: { _ in nil }
        )

        let defaultMetrics = try await service.fetchUsageMetrics(account: .defaultAccount)
        let workMetrics = try await service.fetchUsageMetrics(account: work)

        XCTAssertEqual(defaultMetrics.weeklyLimit?.used, 11)
        XCTAssertEqual(workMetrics.weeklyLimit?.used, 73)
    }

    /// Profiles are fetched concurrently, so the recorded error has to stay
    /// keyed to the profile that produced it — a default-profile success that
    /// lands afterwards must not blank a signed-out profile's error.
    func testDefaultProfileSuccessKeepsASecondaryProfilesError() async throws {
        let work = GrokAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/grok-work")
        let defaultResult = try decodeResult(
            #"{"config":{"creditUsagePercent":11},"subscription_tier":"Default"}"#
        )
        let service = GrokCLIUsageService(
            binaryPathProvider: { "/usr/local/bin/grok" },
            authAvailableProvider: { $0.isDefault },
            billingResultProvider: { _, _ in defaultResult },
            authFileDataProvider: { _ in nil },
            remainingResetsProvider: { _ in nil }
        )

        do {
            _ = try await service.fetchUsageMetrics(account: work)
            XCTFail("Expected the signed-out work profile to fail")
        } catch {
            XCTAssertEqual(
                (error as? ServiceError)?.localizedDescription,
                ServiceError.notAuthenticated.localizedDescription
            )
        }
        _ = try await service.fetchUsageMetrics(account: .defaultAccount)

        XCTAssertEqual(
            service.firstError(for: [work])?.localizedDescription,
            ServiceError.notAuthenticated.localizedDescription
        )
        XCTAssertNil(service.firstError(for: [.defaultAccount]))
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

    /// End-to-end guard for the failure this provider actually shipped with:
    /// the real 0.2.112 transcript has to reach a usable reading, not a
    /// `.parsingError`.
    func testReplayedZeroUsageTranscriptMapsInsteadOfFailingToParse() throws {
        // The CLI sends this frame on one line, so it is assembled from segments
        // rather than wrapped: a newline would split it into two frames and stop
        // testing the transcript the provider actually receives.
        let window = #""start":"2026-07-22T15:05:27.877598+00:00","end":"2026-07-29T15:05:27.877598+00:00""#
        let config = [
            #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\#(window)}"#,
            #""onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}"#,
            #""isUnifiedBillingUser":true"#,
            #""billingPeriodStart":"2026-07-22T15:05:27.877598+00:00""#,
            #""billingPeriodEnd":"2026-07-29T15:05:27.877598+00:00""#
        ].joined(separator: ",")
        let frame = #"{"jsonrpc":"2.0","id":3,"result":{"config":{\#(config)},"subscription_tier":"X Premium"}}"#

        let result = try GrokBillingRPC.result(replaying: transcript(billing: frame))

        XCTAssertEqual(result.subscriptionTier, "X Premium")
        XCTAssertEqual(try GrokCLIUsageService.map(result).weeklyLimit?.used, 0)
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
