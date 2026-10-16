import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Fixtures are synthetic: shaped after the Console billing responses CodexBar's
/// Claude Platform provider documents, not a live capture. They prove the
/// mapping and the failure states, not any account's entitlement.
final class ClaudePlatformParserTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z") ?? Date()

    private static let organizations = Data("""
    [{"uuid":"11111111-1111-4111-8111-111111111111","name":"Chat Org","capabilities":["chat","claude_max"]},
     {"uuid":"22222222-2222-4222-8222-222222222222","name":"API Org",
      "capabilities":["api","api_individual","customer_terms:standard"]}]
    """.utf8)

    private static func credits(
        amount: Int = 18_725,
        exponent: Int = 2,
        currency: String = "USD",
        promo: String = "",
        tranches: String = ""
    ) -> Data {
        Data("""
        {"amount":\(amount),"currency":"\(currency)",
         "balance":{"money":null,"credits":{"amount_minor":\(amount),"exponent":\(exponent)}},
         "promo_tranches":[\(promo)],"tranches":[\(tranches)]}
        """.utf8)
    }

    private static func grant(
        name: String? = nil,
        program: String,
        remaining: Int,
        granted: Int,
        expires: String?
    ) -> String {
        let name = name.map { "\"\($0)\"" } ?? "null"
        let expires = expires.map { "\"\($0)\"" } ?? "null"
        return """
        {"remaining_amount_minor_units":\(remaining),"granted_amount_minor_units":\(granted),
         "expires_at":\(expires),"program_id":"\(program)","name":\(name)}
        """
    }

    private static let subscription = grant(
        name: "API credit (Max 20x)", program: "subscription_api_credit",
        remaining: 12_475, granted: 20_000, expires: "2026-10-28T00:00:00Z"
    )
    private static let purchased = grant(
        program: "api_credits", remaining: 6_250, granted: 10_000, expires: "2027-05-01T00:00:00Z"
    )

    private func reading(_ data: Data, spend: Double? = nil) throws -> ClaudePlatformParser.Reading {
        let credits = try ClaudePlatformParser.credits(data, now: now)
        return try ClaudePlatformParser.reading(
            credits: credits, monthToDateSpend: spend, organizationName: "API Org", now: now
        )
    }

    // MARK: - Organizations

    func testOnlyApiOrganizationsAreCandidates() throws {
        let result = try ClaudePlatformParser.apiOrganizations(Self.organizations)
        XCTAssertEqual(result.map(\.name), ["API Org"])
        XCTAssertEqual(result.first?.id, "22222222-2222-4222-8222-222222222222")
    }

    func testOrganizationWithoutApiCapabilityYieldsNothing() throws {
        let data = Data(#"[{"uuid":"a-1","name":"Chat","capabilities":["chat"]}]"#.utf8)
        XCTAssertEqual(try ClaudePlatformParser.apiOrganizations(data), [])
    }

    func testUnsafeOrganizationIDIsParseDriftNotAPath() {
        let data = Data(#"[{"uuid":"../../etc","name":"X","capabilities":["api"]}]"#.utf8)
        XCTAssertThrowsError(try ClaudePlatformParser.apiOrganizations(data))
    }

    func testNonArrayOrganizationsIsParseDrift() {
        XCTAssertThrowsError(try ClaudePlatformParser.apiOrganizations(Data(#"{"a":1}"#.utf8)))
        XCTAssertThrowsError(try ClaudePlatformParser.apiOrganizations(Data("not json".utf8)))
    }

    // MARK: - Credits → metrics

    func testSubscriptionGrantIsThePrimaryLaneAndPurchasedCreditIsBesideIt() throws {
        let result = try reading(Self.credits(promo: Self.subscription, tranches: Self.purchased), spend: 43.21)

        let weekly = try XCTUnwrap(result.metrics.weeklyLimit)
        XCTAssertEqual(weekly.total, 200, accuracy: 0.0001)
        XCTAssertEqual(weekly.used, 75.25, accuracy: 0.0001)
        XCTAssertNil(weekly.resetTime, "a credit grant expires; it never resets")
        XCTAssertEqual(weekly.reading, .measured)

        XCTAssertNil(result.metrics.sessionLimit)
        let extra = try XCTUnwrap(result.metrics.additionalLimits.first)
        XCTAssertEqual(extra.label, "Purchased credit")
        XCTAssertEqual(extra.total, 100, accuracy: 0.0001)
        XCTAssertEqual(extra.used, 37.5, accuracy: 0.0001)

        XCTAssertEqual(result.summary.balance, 187.25, accuracy: 0.0001)
        XCTAssertEqual(result.summary.monthToDateSpend, 43.21)
        XCTAssertEqual(result.summary.nextExpiry, ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z"))
    }

    func testSoonestExpiringSubscriptionGrantWithCreditWins() throws {
        let later = Self.grant(
            name: "Later", program: "subscription_api_credit", remaining: 15_000, granted: 20_000,
            expires: "2026-11-12T00:00:00Z"
        )
        let exhaustedSooner = Self.grant(
            name: "Spent", program: "subscription_api_credit", remaining: 0, granted: 5_000,
            expires: "2026-10-20T00:00:00Z"
        )
        let result = try reading(Self.credits(promo: [later, exhaustedSooner].joined(separator: ",")))

        XCTAssertEqual(result.metrics.weeklyLimit?.total ?? 0, 200, accuracy: 0.0001)
        XCTAssertEqual(result.metrics.weeklyLimit?.used ?? 0, 50, accuracy: 0.0001)
        XCTAssertTrue(result.metrics.additionalLimits.isEmpty, "exhausted grants are not rows")
    }

    func testExhaustedSubscriptionGrantFallsBackToPurchasedCredit() throws {
        let spent = Self.grant(
            program: "subscription_api_credit", remaining: 0, granted: 20_000, expires: "2026-10-28T00:00:00Z"
        )
        let result = try reading(Self.credits(promo: spent, tranches: Self.purchased))

        XCTAssertEqual(result.metrics.weeklyLimit?.total ?? 0, 100, accuracy: 0.0001)
        XCTAssertTrue(result.metrics.additionalLimits.isEmpty)
    }

    func testExpiredGrantsDropOutAndExpiryExactlyNowCountsAsExpired() throws {
        let expiringNow = Self.grant(
            program: "subscription_api_credit", remaining: 5_000, granted: 10_000, expires: "2026-10-13T00:00:00Z"
        )
        let expired = Self.grant(
            program: "api_credits", remaining: 4_000, granted: 4_000, expires: "2026-10-12T00:00:00Z"
        )
        let credits = try ClaudePlatformParser.credits(
            Self.credits(promo: expiringNow, tranches: expired), now: now
        )
        XCTAssertTrue(credits.grants.isEmpty)
    }

    func testUnparseableExpiryIsUnknownNotAFailure() throws {
        let odd = Self.grant(
            program: "api_credits", remaining: 2_500, granted: 5_000, expires: "2026-10-31Tnot-a-date"
        )
        let credits = try ClaudePlatformParser.credits(Self.credits(tranches: odd), now: now)
        XCTAssertEqual(credits.grants.count, 1)
        XCTAssertNil(credits.grants.first?.expiresAt)
    }

    func testBalanceWithoutAnyGrantIsARemainderNeverAPercent() throws {
        let result = try reading(Self.credits(amount: 5_000))
        let weekly = try XCTUnwrap(result.metrics.weeklyLimit)
        XCTAssertEqual(weekly.reading, .remainder)
        XCTAssertEqual(weekly.total, 50, accuracy: 0.0001)
        XCTAssertFalse(weekly.hasDepletingMeter)
    }

    func testZeroBalanceWithoutGrantsHasNoLimit() throws {
        let result = try reading(Self.credits(amount: 0))
        XCTAssertNil(result.metrics.weeklyLimit)
        XCTAssertFalse(result.metrics.hasData)
    }

    func testAmountsUseTheReportedExponent() throws {
        let grant = Self.grant(
            program: "subscription_api_credit", remaining: 124_750, granted: 200_000,
            expires: "2026-10-28T00:00:00Z"
        )
        let credits = try ClaudePlatformParser.credits(
            Self.credits(amount: 187_250, exponent: 3, promo: grant), now: now
        )
        XCTAssertEqual(credits.balance, 187.25, accuracy: 0.0001)
        XCTAssertEqual(credits.grants.first?.remaining ?? 0, 124.75, accuracy: 0.0001)
        XCTAssertEqual(ClaudePlatformParser.monthToDateSpend(Data(#"{"amount":43210}"#.utf8), exponent: 3), 43.21)
    }

    func testMissingExponentDefaultsToCents() throws {
        let data = Data(#"{"amount":18725,"currency":"USD","tranches":[],"promo_tranches":[]}"#.utf8)
        XCTAssertEqual(try ClaudePlatformParser.credits(data, now: now).balance, 187.25, accuracy: 0.0001)
    }

    func testOutOfRangeExponentIsParseDrift() {
        XCTAssertThrowsError(try ClaudePlatformParser.credits(Self.credits(exponent: 9), now: now))
    }

    func testNonUSDCurrencyIsRefusedRatherThanLabelledDollars() throws {
        let credits = try ClaudePlatformParser.credits(Self.credits(currency: "EUR"), now: now)
        XCTAssertThrowsError(
            try ClaudePlatformParser.reading(
                credits: credits, monthToDateSpend: nil, organizationName: nil, now: now
            )
        )
    }

    func testMalformedCreditsAreParseDriftNotZero() {
        for body in [
            "not json",
            "[]",
            #"{"currency":"USD"}"#,
            #"{"amount":"187","currency":"USD"}"#,
            #"{"amount":1.5,"currency":"USD"}"#,
            #"{"amount":100,"currency":"usd"}"#,
            #"{"amount":100,"currency":"USD","tranches":{"a":1}}"#,
            #"{"amount":100,"currency":"USD","tranches":[{"granted_amount_minor_units":10}]}"#
        ] {
            XCTAssertThrowsError(try ClaudePlatformParser.credits(Data(body.utf8), now: now), body)
        }
    }

    func testBooleanAmountsAreNotNumbers() {
        let body = #"{"amount":true,"currency":"USD"}"#
        XCTAssertThrowsError(try ClaudePlatformParser.credits(Data(body.utf8), now: now))
    }

    func testGrantRecordCountIsBounded() {
        let one = Self.grant(program: "api_credits", remaining: 1, granted: 1, expires: nil)
        let many = Array(repeating: one, count: 201).joined(separator: ",")
        XCTAssertThrowsError(try ClaudePlatformParser.credits(Self.credits(tranches: many), now: now))
    }

    func testAdditionalGrantRowsAreCapped() throws {
        let grants = (0..<10).map {
            Self.grant(
                name: "Promo \($0)", program: "promo", remaining: 100, granted: 100,
                expires: "2026-12-\(String(format: "%02d", $0 + 1))T00:00:00Z"
            )
        }
        let result = try reading(Self.credits(promo: grants.joined(separator: ",")))
        XCTAssertLessThanOrEqual(
            result.metrics.additionalLimits.count, ClaudePlatformParser.maximumAdditionalGrants
        )
    }

    func testSpendIsOptional() {
        XCTAssertNil(ClaudePlatformParser.monthToDateSpend(Data("nope".utf8), exponent: 2))
        XCTAssertNil(ClaudePlatformParser.monthToDateSpend(Data(#"{"amount":-5}"#.utf8), exponent: 2))
        XCTAssertNil(ClaudePlatformParser.monthToDateSpend(Data(#"{"other":1}"#.utf8), exponent: 2))
    }

    func testMetricsRoundTripThroughTheSharedCacheCodec() throws {
        let result = try reading(Self.credits(promo: Self.subscription, tranches: Self.purchased))
        let encoded = try JSONEncoder().encode(result.metrics)
        let decoded = try JSONDecoder().decode(UsageMetrics.self, from: encoded)
        XCTAssertEqual(decoded.service, .claudePlatform)
        XCTAssertEqual(decoded.weeklyLimit, result.metrics.weeklyLimit)
        XCTAssertEqual(decoded.additionalLimits, result.metrics.additionalLimits)
    }

    // MARK: - Pasted credential

    func testSessionKeyIsExtractedFromAWholeCookieHeader() {
        XCTAssertEqual(
            ClaudePlatformSessionKey.normalized("Cookie: foo=1; sessionKey=sk-ant-sid01-abc_DEF; other=2"),
            "sk-ant-sid01-abc_DEF"
        )
        XCTAssertEqual(ClaudePlatformSessionKey.normalized("sessionKey=sk-ant-x"), "sk-ant-x")
        XCTAssertEqual(ClaudePlatformSessionKey.normalized("  sk-ant-sid01-raw  "), "sk-ant-sid01-raw")
    }

    func testSessionKeyRejectsHeaderInjectionAndMissingCookie() {
        XCTAssertNil(ClaudePlatformSessionKey.normalized(""))
        XCTAssertNil(ClaudePlatformSessionKey.normalized("foo=1; bar=2"))
        XCTAssertNil(ClaudePlatformSessionKey.normalized("sessionKey="))
        XCTAssertNil(ClaudePlatformSessionKey.normalized("sessionKey=abc\r\nX-Evil: 1"))
        XCTAssertNil(ClaudePlatformSessionKey.normalized("sk-ant with space"))
        XCTAssertNil(ClaudePlatformSessionKey.normalized(String(repeating: "a", count: 5_000)))
    }
}
