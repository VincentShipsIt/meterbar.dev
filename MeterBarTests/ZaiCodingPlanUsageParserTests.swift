import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Fixture coverage for `ZaiCodingPlanUsageParser`. Payloads are redacted by
/// construction: only the fields the parser reads, with synthetic numbers.
final class ZaiCodingPlanUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ json: String) throws -> ZaiCodingPlanUsageParser.Result {
        try ZaiCodingPlanUsageParser.parse(Data(json.utf8), now: now)
    }

    private func envelope(_ limits: String, level: String = "pro") -> String {
        #"{"code":200,"msg":"Operation successful","success":true,"data":{"level":"\#(level)","limits":[\#(limits)]}}"#
    }

    private let fiveHour = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12,"nextResetTime":1790003600000}"#
    private let weekly = #"{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":4,"nextResetTime":1790500000000}"#
    private let tools = """
    {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":120,"remaining":880,"percentage":12,
     "nextResetTime":1792000000000,"usageDetails":[{"modelCode":"search-prime","usage":100}]}
    """

    // MARK: - Windows

    func testFiveHourWeeklyAndMonthlyToolWindowsMap() throws {
        let result = try parse(envelope("\(fiveHour),\(weekly),\(tools)"))
        let metrics = result.metrics

        XCTAssertEqual(metrics.service, .zaiCodingPlan)
        XCTAssertEqual(metrics.sessionLimit?.used, 12)
        XCTAssertEqual(metrics.sessionLimit?.total, 100)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 3_600)
        XCTAssertEqual(metrics.sessionLimit?.periodKind, .session)
        XCTAssertEqual(metrics.sessionLimit?.resetTime, Date(timeIntervalSince1970: 1_790_003_600))
        XCTAssertEqual(metrics.weeklyLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.windowSeconds, 7 * 24 * 3_600)
        XCTAssertEqual(metrics.weeklyLimit?.periodKind, .weekly)

        let tool = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(metrics.additionalLimits.count, 1)
        XCTAssertEqual(tool.used, 120)
        XCTAssertEqual(tool.total, 1_000)
        XCTAssertEqual(tool.periodKind, .monthly)
        XCTAssertEqual(tool.label, "MCP tools")
        XCTAssertEqual(metrics.lastUpdated, now)
        XCTAssertEqual(result.plan, "pro")
    }

    func testTokenLimitOnlyPlanHasNoWeeklyOrToolWindow() throws {
        let metrics = try parse(envelope(fiveHour)).metrics

        XCTAssertNotNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testTokenLimitWithoutUnitsIsTheOfficialPluginsFiveHourWindow() throws {
        let metrics = try parse(envelope(#"{"type":"TOKENS_LIMIT","percentage":40}"#)).metrics

        XCTAssertEqual(metrics.sessionLimit?.used, 40)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 3_600)
        XCTAssertNil(metrics.sessionLimit?.resetTime)
    }

    func testUnknownUnitBecomesANeutralQuotaWindow() throws {
        let metrics = try parse(
            envelope(#"{"type":"TOKENS_LIMIT","unit":9,"number":2,"percentage":30}"#)
        ).metrics

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit)
        let limit = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(limit.periodKind, .unknown)
        XCTAssertNil(limit.windowSeconds)
        XCTAssertEqual(ServiceType.zaiCodingPlan.additionalQuotaTitleKey(for: limit).englishTitle, "Quota")
    }

    func testInvalidUnitsRemainNeutralWithoutDiscardingUsage() throws {
        for unit in ["1.5", "3.5", "5.5", "6.5", "1e100", "-1e100", "9223372036854775808", "\"1e100\""] {
            let item = #"{"type":"TOKENS_LIMIT","unit":\#(unit),"number":5,"percentage":30}"#
            let metrics = try parse(envelope(item)).metrics
            XCTAssertNil(metrics.sessionLimit)
            XCTAssertNil(metrics.weeklyLimit)
            let limit = try XCTUnwrap(metrics.additionalLimits.first)
            XCTAssertEqual(limit.used, 30)
            XCTAssertEqual(limit.periodKind, .unknown)
            XCTAssertNil(limit.windowSeconds)
        }
    }

    func testDayWindowIsDaily() throws {
        let metrics = try parse(envelope(#"{"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":30}"#)).metrics

        XCTAssertEqual(metrics.additionalLimits.first?.periodKind, .daily)
    }

    func testAnExtraFiveHourWindowDoesNotOverwriteTheFirst() throws {
        let metrics = try parse(envelope("\(fiveHour),\(fiveHour.replacingOccurrences(of: "12", with: "77"))")).metrics

        XCTAssertEqual(metrics.sessionLimit?.used, 12)
        XCTAssertEqual(metrics.additionalLimits.count, 1)
    }

    func testToolWindowWithoutACapIsOmittedRatherThanShownAsHealthy() throws {
        let noCap = #"{"type":"TIME_LIMIT","unit":5,"number":1,"usage":0,"currentValue":0,"remaining":0,"percentage":0}"#
        let metrics = try parse(envelope("\(fiveHour),\(noCap)")).metrics

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testToolWindowUsesRemainingWhenCurrentValueIsAbsent() throws {
        let item = #"{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"remaining":250}"#
        let metrics = try parse(envelope("\(fiveHour),\(item)")).metrics

        XCTAssertEqual(metrics.additionalLimits.first?.used, 750)
    }

    func testNumericStringsAndSecondBasedResetsAreAccepted() throws {
        let item = #"{"type":"TOKENS_LIMIT","unit":"3","number":"5","percentage":"25","nextResetTime":"1790003600"}"#
        let metrics = try parse(envelope(item)).metrics

        XCTAssertEqual(metrics.sessionLimit?.used, 25)
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 5 * 3_600)
        XCTAssertEqual(metrics.sessionLimit?.resetTime, Date(timeIntervalSince1970: 1_790_003_600))
    }

    func testISOResetStringsAreAccepted() throws {
        let item = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":"2026-09-11T18:00:00Z"}"#

        XCTAssertNotNil(try parse(envelope(item)).metrics.sessionLimit?.resetTime)
    }

    func testUnknownTypesAndUnreadableEntriesAreDropped() throws {
        let metrics = try parse(envelope("""
        \(fiveHour),
        {"type":"IMAGE_LIMIT","percentage":50},
        {"type":"TOKENS_LIMIT","unit":6,"number":1},
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":-3},
        "not an object"
        """)).metrics

        XCTAssertNotNil(metrics.sessionLimit)
        XCTAssertNil(metrics.weeklyLimit, "an entry with no readable percentage is not 0%")
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    func testAdditiveFieldsAreTolerated() throws {
        let json = #"""
        {"code":200,"success":true,"future":{"a":1},"data":{"level":"max","extra":[1],"limits":[
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":9,"newField":"x"}]}}
        """#

        XCTAssertEqual(try parse(json).metrics.sessionLimit?.used, 9)
    }

    // MARK: - Plan token

    func testPlanIsKeptOnlyWhenItIsAPlainShortToken() throws {
        XCTAssertEqual(try parse(envelope(fiveHour, level: "lite")).plan, "lite")
        XCTAssertNil(try parse(envelope(fiveHour, level: "")).plan)
        XCTAssertNil(try parse(envelope(fiveHour, level: "a plan with spaces and <markup>")).plan)
        XCTAssertNil(try parse(envelope(fiveHour, level: String(repeating: "x", count: 40))).plan)
    }

    // MARK: - Honest failure

    func testFailureEnvelopesMapToAuthOrAPIErrors() {
        for body in [
            #"{"code":401,"msg":"token expired","success":false}"#,
            #"{"code":1001,"msg":"Authorization Token missing","success":false}"#,
            #"{"success":false,"code":"1002","msg":"invalid"}"#
        ] {
            XCTAssertThrowsError(try parse(body), body) { error in
                guard case ServiceError.notAuthenticated = error else {
                    return XCTFail("expected notAuthenticated for \(body), got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try parse(#"{"code":500,"msg":"boom {raw body}","success":false}"#)) { error in
            guard case let ServiceError.apiError(message) = error else {
                return XCTFail("expected apiError, got \(error)")
            }
            XCTAssertEqual(message, "Request failed", "provider text must never be surfaced")
        }
    }

    func testInvalidFailureCodesRemainAPIErrors() {
        for code in ["1e100", "-1e100", "9223372036854775808", "401.5", "1001.5", "200.5", "\"1e100\""] {
            // A readable payload and success=true must not hide a raw non-200 code.
            let body = #"{"code":\#(code),"success":true,"data":{"limits":[\#(fiveHour)]}}"#
            XCTAssertThrowsError(try parse(body), code) { error in
                guard case let ServiceError.apiError(message) = error else {
                    return XCTFail("expected apiError for \(code), got \(error)")
                }
                XCTAssertEqual(message, "Request failed")
            }
        }
    }

    func testExactAuthCodesRemainAuthenticationFailures() {
        for code in [401, 1000, 1001, 1002, 1003, 1004] {
            XCTAssertThrowsError(try parse(#"{"code":\#(code),"success":true}"#)) { error in
                guard case ServiceError.notAuthenticated = error else {
                    return XCTFail("expected authentication failure for \(code), got \(error)")
                }
            }
        }
    }

    func testUnreadablePayloadsFailInsteadOfReportingZeroPercent() {
        for body in [
            "",
            "not json",
            "[]",
            "null",
            "{}",
            #"{"code":200,"success":true}"#,
            #"{"code":200,"success":true,"data":{}}"#,
            #"{"code":200,"success":true,"data":{"limits":[]}}"#,
            #"{"code":200,"success":true,"data":{"limits":"none"}}"#,
            #"{"code":200,"success":true,"data":{"limits":[{"type":"UNKNOWN_LIMIT","percentage":5}]}}"#,
            #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT"}]}}"#
        ] {
            XCTAssertThrowsError(try parse(body), "body: \(body)") { error in
                guard case ServiceError.parsingError = error else {
                    return XCTFail("expected a parsing error for \(body), got \(error)")
                }
            }
        }
    }

    func testParsedMetricsCarryNoRawBodyContent() throws {
        let metrics = try parse(envelope("\(fiveHour),\(tools)")).metrics

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(metrics), encoding: .utf8))
        XCTAssertFalse(encoded.contains("search-prime"), "per-tool usage details are never stored")
        XCTAssertFalse(encoded.contains("Operation successful"))
    }
}
