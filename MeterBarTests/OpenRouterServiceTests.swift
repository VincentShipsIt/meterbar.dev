import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class OpenRouterServiceTests: XCTestCase {
    func testOfficialCreditAndKeyFixturesMapToCurrencyLimits() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":100.5,"total_usage":25.75}}"#)
        let key = try decodeKey(
            #"{"data":{"label":"MeterBar","limit":40,"limit_reset":"monthly","limit_remaining":12.5,"usage":27.5,"usage_daily":1.25,"usage_weekly":8,"usage_monthly":20,"is_free_tier":false}}"#
        )
        let now = date(2026, 7, 13)

        let metrics = OpenRouterService.map(credits: credits.data, key: key.data, now: now)

        XCTAssertEqual(metrics.service, .openRouter)
        XCTAssertEqual(metrics.weeklyLimit?.used, 25.75)
        XCTAssertEqual(metrics.weeklyLimit?.total, 100.5)
        XCTAssertEqual(metrics.sessionLimit?.used, 27.5)
        XCTAssertEqual(metrics.sessionLimit?.total, 40)
        XCTAssertEqual(metrics.sessionLimit?.resetTime, date(2026, 8, 1))
        XCTAssertNil(metrics.sessionLimit?.windowSeconds)
    }

    func testUnlimitedKeyOmitsKeyLimitButKeepsAccountCredits() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":10,"total_usage":4}}"#)
        let key = try decodeKey(
            #"{"data":{"label":"Unlimited","limit":null,"limit_reset":null,"limit_remaining":null,"usage":4,"is_free_tier":false}}"#
        )

        let metrics = OpenRouterService.map(credits: credits.data, key: key.data)

        XCTAssertNil(metrics.sessionLimit)
        XCTAssertEqual(metrics.weeklyLimit?.used, 4)
        XCTAssertEqual(metrics.weeklyLimit?.total, 10)
    }

    func testZeroBalanceStillProducesVisibleAccountCredits() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":0,"total_usage":0}}"#)
        let key = try decodeKey(
            #"{"data":{"limit":null,"limit_reset":null,"limit_remaining":null,"usage":0,"is_free_tier":true}}"#
        )

        let metrics = OpenRouterService.map(credits: credits.data, key: key.data)

        XCTAssertNotNil(metrics.weeklyLimit)
        XCTAssertEqual(metrics.weeklyLimit?.used, 0)
        XCTAssertEqual(metrics.weeklyLimit?.total, 0)
    }

    func testDailyKeyLimitMapsToNextUTCReset() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":20,"total_usage":5}}"#)
        let key = try decodeKey(
            #"{"data":{"limit":5,"limit_reset":"daily","limit_remaining":2,"usage":3,"is_free_tier":true}}"#
        )

        let metrics = OpenRouterService.map(
            credits: credits.data,
            key: key.data,
            now: date(2026, 7, 13, 16)
        )

        XCTAssertEqual(metrics.sessionLimit?.resetTime, date(2026, 7, 14))
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 86_400)
    }

    private func decodeCredits(_ json: String) throws -> OpenRouterCreditsResponse {
        try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: Data(json.utf8))
    }

    private func decodeKey(_ json: String) throws -> OpenRouterKeyResponse {
        try JSONDecoder().decode(OpenRouterKeyResponse.self, from: Data(json.utf8))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }
}
