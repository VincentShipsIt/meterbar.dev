import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Fixture coverage for `KimiCodeUsageParser`. Every payload here is redacted
/// by construction: only the fields the parser reads, with synthetic numbers.
final class KimiCodeUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ json: String) throws -> UsageMetrics {
        try KimiCodeUsageParser.metrics(from: Data(json.utf8), now: now)
    }

    private func iso(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    // MARK: - Quota model (current)

    func testQuotaModelMapsFiveHourAndWeeklyWindowsWithTheirResets() throws {
        let metrics = try parse("""
        {"goods_version":2,"usages":{
          "limit_5h":{"used_ratio":0.3,"reset_time":"2026-09-11T18:00:00Z"},
          "limit_7d":{"used_ratio":0.2,"reset_time":"2026-09-17T00:00:00Z"}}}
        """)

        XCTAssertEqual(metrics.service, .kimiCode)
        XCTAssertEqual(metrics.sessionLimit?.used ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(metrics.sessionLimit?.total, 100)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 3_600)
        XCTAssertEqual(metrics.sessionLimit?.periodKind, .session)
        XCTAssertEqual(metrics.sessionLimit?.resetTime, iso("2026-09-11T18:00:00Z"))
        XCTAssertEqual(metrics.weeklyLimit?.used ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 7 * 24 * 3_600)
        XCTAssertEqual(metrics.weeklyLimit?.periodKind, .weekly)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertNil(metrics.extraUsage)
        XCTAssertEqual(metrics.lastUpdated, now)
    }

    func testMonthlyWindowsRideInAdditionalLimitsBesideTheWeeklyOne() throws {
        let metrics = try parse("""
        {"usages":{
          "limit_5h":{"used_ratio":0.1},
          "limit_7d":{"used_ratio":0.2},
          "limit_month_total":{"used_ratio":0.4,"reset_time":"2026-10-01T00:00:00Z"},
          "limit_month_code":{"used_ratio":0.25,"reset_time":"2026-10-01T00:00:00Z"}}}
        """)

        XCTAssertEqual(metrics.additionalLimits.count, 2)
        XCTAssertEqual(metrics.additionalLimits.map(\.periodKind), [.monthly, .monthly])
        XCTAssertEqual(metrics.additionalLimits.map(\.used), [40, 25])
        XCTAssertNil(metrics.additionalLimits[0].label)
        XCTAssertEqual(metrics.additionalLimits[1].label, "Monthly code")
        // Two monthly bars must not both title as "Monthly".
        let titles = metrics.additionalLimits.map { ServiceType.kimiCode.additionalQuotaTitleKey(for: $0).englishTitle }
        XCTAssertEqual(titles, ["Monthly", "Monthly code"])
    }

    func testPlanWithOnlyAMonthlyWindowStillDrivesTheWeeklySlot() throws {
        let metrics = try parse(#"{"usages":{"limit_month_total":{"used_ratio":0.5}}}"#)

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertEqual(metrics.weeklyLimit?.used, 50)
        XCTAssertEqual(metrics.weeklyLimit?.periodKind, .monthly)
        XCTAssertNil(metrics.weeklyLimit?.windowSeconds, "a month has no fixed length")
    }

    func testNumericStringsAreAccepted() throws {
        let metrics = try parse(#"{"usages":{"limit_5h":{"used_ratio":"0.25"},"limit_7d":{"used_ratio":"0.5"}}}"#)

        XCTAssertEqual(metrics.sessionLimit?.used, 25)
        XCTAssertEqual(metrics.weeklyLimit?.used, 50)
    }

    func testOverQuotaRatioIsKeptButClampedForDisplay() throws {
        let metrics = try parse(#"{"usages":{"limit_5h":{"used_ratio":1.2}}}"#)

        let session = try XCTUnwrap(metrics.sessionLimit)
        XCTAssertEqual(session.rawPercentage, 120, accuracy: 0.0001)
        XCTAssertEqual(session.percentage, 100)
        XCTAssertTrue(session.isAtLimit)
    }

    func testMissingResetTimeIsLeftOutNeverInvented() throws {
        let metrics = try parse(#"{"usages":{"limit_5h":{"used_ratio":0.3,"reset_time":""},"limit_7d":{"used_ratio":0.3,"reset_time":42}}}"#)

        XCTAssertNil(metrics.sessionLimit?.resetTime)
        XCTAssertNil(metrics.weeklyLimit?.resetTime)
    }

    func testFractionalSecondResetTimesParse() throws {
        let metrics = try parse(#"{"usages":{"limit_5h":{"used_ratio":0.3,"reset_time":"2026-09-11T18:00:00.500Z"}}}"#)

        let reset = try XCTUnwrap(metrics.sessionLimit?.resetTime)
        let plainReset = try XCTUnwrap(iso("2026-09-11T18:00:00Z"))
        XCTAssertEqual(reset.timeIntervalSince1970, plainReset.timeIntervalSince1970 + 0.5)
    }

    func testUnsupportedResetFormatIsOmittedWhilePlainResetStillParses() throws {
        let metrics = try parse("""
        {"usages":{
          "limit_5h":{"used_ratio":0.3,"reset_time":"not-a-timestamp"},
          "limit_7d":{"used_ratio":0.4,"reset_time":"2026-09-17T00:00:00Z"}}}
        """)

        XCTAssertNil(metrics.sessionLimit?.resetTime)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, iso("2026-09-17T00:00:00Z"))
    }

    func testEntriesWithoutAReadableRatioAreDroppedNotZeroed() throws {
        let metrics = try parse("""
        {"usages":{
          "limit_5h":"half",
          "limit_7d":{"reset_time":"2026-09-17T00:00:00Z"},
          "limit_month_total":{"used_ratio":-0.1},
          "limit_month_code":{"used_ratio":"0.25"}}}
        """)

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        // The one readable entry is the monthly-code window, which never
        // stands in for the weekly slot: it rides as an additional window.
        XCTAssertEqual(metrics.additionalLimits.map(\.used), [25])
    }

    func testAdditiveUnknownFieldsAreTolerated() throws {
        let metrics = try parse("""
        {"goods_version":3,"new_top_level":{"a":1},"usages":{
          "limit_5h":{"used_ratio":0.3,"extra":"x"},
          "limit_1y":{"used_ratio":0.9}}}
        """)

        XCTAssertEqual(metrics.sessionLimit?.used, 30)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertTrue(metrics.additionalLimits.isEmpty, "an unknown limit key is never guessed into a window")
    }

    // MARK: - Row model (previous)

    func testRowModelMapsSummaryAndFiveHourWindow() throws {
        let metrics = try parse("""
        {"usage":{"used":"40","limit":"1000","resetTime":"2026-08-03T05:20:51Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"used":"1","limit":"100","resetTime":"2026-08-01T10:00:00Z"}}]}
        """)

        XCTAssertEqual(metrics.sessionLimit?.used, 1)
        XCTAssertEqual(metrics.sessionLimit?.total, 100)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 3_600)
        XCTAssertEqual(metrics.sessionLimit?.periodKind, .session)
        XCTAssertEqual(metrics.weeklyLimit?.used, 40)
        XCTAssertEqual(metrics.weeklyLimit?.total, 1_000)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 7 * 24 * 3_600)
        XCTAssertEqual(metrics.weeklyLimit?.periodKind, .weekly)
        XCTAssertEqual(metrics.weeklyLimit?.resetTime, iso("2026-08-03T05:20:51Z"))
    }

    func testRowModelUnknownTimeUnitBecomesANeutralQuotaWindow() throws {
        let metrics = try parse("""
        {"limits":[{"window":{"duration":3,"timeUnit":"TIME_UNIT_FORTNIGHT"},
                    "detail":{"used":"5","limit":"50"}}]}
        """)

        let limit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(limit.periodKind, .unknown)
        XCTAssertNil(limit.windowSeconds)
        XCTAssertEqual(ServiceType.kimiCode.additionalQuotaTitleKey(for: limit).englishTitle, "Quota")
    }

    func testRowModelDayWindowIsDaily() throws {
        let metrics = try parse("""
        {"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"used":"5","limit":"50"}}]}
        """)

        XCTAssertEqual(metrics.additionalLimits.first?.periodKind, .daily)
        XCTAssertEqual(metrics.additionalLimits.first?.windowSeconds, 86_400)
    }

    func testRowModelUsesRemainingWhenUsedIsAbsent() throws {
        let metrics = try parse(#"{"usage":{"limit":"100","remaining":"30"}}"#)

        XCTAssertEqual(metrics.weeklyLimit?.used, 70)
    }

    func testRowModelRowsWithoutAUsableDenominatorOrUsageAreSkipped() throws {
        XCTAssertThrowsError(try parse(#"{"usage":{"used":"5","limit":"0"}}"#))
        XCTAssertThrowsError(try parse(#"{"usage":{"limit":"100"}}"#), "no used/remaining must not read as 0%")
        XCTAssertThrowsError(try parse(#"{"limits":[{"window":{},"detail":{"used":"x","limit":"y"}}]}"#))
    }

    func testQuotaModelWinsWhenBothShapesArePresent() throws {
        let metrics = try parse("""
        {"usages":{"limit_5h":{"used_ratio":0.5}},
         "usage":{"used":"1","limit":"100"}}
        """)

        XCTAssertEqual(metrics.sessionLimit?.used, 50)
        XCTAssertNil(metrics.weeklyLimit)
    }

    // MARK: - Booster wallet

    private let walletFixture = """
    {"usages":{"limit_5h":{"used_ratio":0.1}},
     "boosterWallet":{
       "balance":{"type":"BOOSTER","amount":"20000000000","amountLeft":"10000000000"},
       "monthlyChargeLimitEnabled":true,
       "monthlyChargeLimit":{"currency":"USD","priceInCents":"20000"},
       "monthlyUsed":{"currency":"USD","priceInCents":"5000"}}}
    """

    func testBoosterWalletMapsToExtraUsageWithReadableAmounts() throws {
        let extra = try XCTUnwrap(try parse(walletFixture).extraUsage)

        XCTAssertEqual(extra.state, .on)
        XCTAssertEqual(extra.detail, "\(ExtraUsageStatus.formatAmount(100, currency: "USD")) left of \(ExtraUsageStatus.formatAmount(200, currency: "USD"))")
    }

    func testDepletedBoosterWalletIsOff() throws {
        let json = walletFixture.replacingOccurrences(of: #""amountLeft":"10000000000""#, with: #""amountLeft":"0""#)

        XCTAssertEqual(try parse(json).extraUsage?.state, .off)
    }

    func testBoosterWalletWithoutAReadableCurrencyIsOmitted() throws {
        let json = """
        {"usages":{"limit_5h":{"used_ratio":0.1}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amount":"20000000000","amountLeft":"10000000000"}}}
        """

        XCTAssertNil(try parse(json).extraUsage)
        let badCode = walletFixture.replacingOccurrences(of: "USD", with: "US$")
        XCTAssertNil(try parse(badCode).extraUsage)
    }

    func testNonBoosterOrUnreadableWalletIsOmitted() throws {
        for wallet in [
            #"{}"#,
            #"{"balance":{"type":"PLAN","amount":"1","amountLeft":"1"}}"#,
            #"{"balance":{"type":"BOOSTER","amount":"0","amountLeft":"0"}}"#,
            #"{"balance":{"type":"BOOSTER","amount":"abc","amountLeft":"1"}}"#,
            #""not an object""#
        ] {
            let json = #"{"usages":{"limit_5h":{"used_ratio":0.1}},"boosterWallet":\#(wallet)}"#
            XCTAssertNil(try parse(json).extraUsage, wallet)
        }
    }

    // MARK: - Honest failure

    func testUnreadablePayloadsFailInsteadOfReportingZeroPercent() {
        for body in [
            "",
            "not json",
            "[]",
            "\"usages\"",
            "null",
            "{}",
            #"{"usages":{}}"#,
            #"{"usages":{"limit_5h":{},"limit_7d":"x"}}"#,
            #"{"usages":[]}"#,
            #"{"limits":[]}"#,
            #"{"boosterWallet":{"balance":{"type":"BOOSTER","amount":"20000000000","amountLeft":"1"}}}"#
        ] {
            XCTAssertThrowsError(try parse(body), "body: \(body)") { error in
                guard case ServiceError.parsingError = error else {
                    return XCTFail("expected a parsing error for \(body), got \(error)")
                }
            }
        }
    }

    func testBooleanRatioIsNotAQuantity() {
        XCTAssertThrowsError(try parse(#"{"usages":{"limit_5h":{"used_ratio":true}}}"#))
    }

    func testParsedMetricsCarryNoRawBodyContent() throws {
        let metrics = try parse("""
        {"usages":{"limit_5h":{"used_ratio":0.3}},
         "account_email":"person@example.com","internal_note":"do-not-store"}
        """)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(metrics), encoding: .utf8))
        XCTAssertFalse(encoded.contains("person@example.com"))
        XCTAssertFalse(encoded.contains("do-not-store"))
    }
}
