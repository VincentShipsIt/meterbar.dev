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

    func testWeeklyKeyLimitMapsToNextUTCWeekReset() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":20,"total_usage":5}}"#)
        let key = try decodeKey(
            #"{"data":{"limit":10,"limit_reset":"weekly","limit_remaining":4,"usage":6,"is_free_tier":false}}"#
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let metrics = OpenRouterService.map(
            credits: credits.data,
            key: key.data,
            now: date(2026, 7, 15, 16),
            calendar: calendar
        )

        XCTAssertEqual(metrics.sessionLimit?.resetTime, date(2026, 7, 20))
        XCTAssertEqual(metrics.sessionLimit?.windowSeconds, 604_800)
    }

    // MARK: - Poll observations

    /// OpenRouter denominates `usage` and `usage_daily` in dollars, so the
    /// observation is `.usd` and no conversion is involved. If this ever became
    /// `.requests` the ledger would stop folding OpenRouter into `costs[]`
    /// entirely; if a request-denominated provider were ever marked `.usd`, its
    /// counter would be published as money.
    func testKeyResponseObservesRunningSpendInDollars() throws {
        let key = try decodeKey(
            #"{"data":{"limit":40,"limit_reset":"monthly","usage":27.5,"usage_daily":1.25,"is_free_tier":false}}"#
        )
        let now = date(2026, 7, 13)

        let observation = OpenRouterService.observation(key: key.data, at: now)

        XCTAssertEqual(observation.provider, .openRouter)
        XCTAssertEqual(observation.unit, .usd)
        XCTAssertEqual(observation.runningTotal, 27.5)
        XCTAssertEqual(observation.authoritativeDailyTotal, 1.25)
        XCTAssertEqual(observation.observedAt, now)
    }

    /// `usage_daily` is spend since midnight UTC, and the ledger writes it into
    /// its day absolutely. Dated against a local calendar it would land in the
    /// wrong day for every user off UTC — and overwrite whatever that day had
    /// legitimately accumulated from deltas.
    func testDailyTotalIsDatedAgainstUTCNotTheUsersCalendar() throws {
        let key = try decodeKey(#"{"data":{"limit":40,"limit_reset":"monthly","usage":27.5,"usage_daily":1.25}}"#)

        let observation = OpenRouterService.observation(key: key.data, at: date(2026, 7, 13))

        XCTAssertEqual(observation.dayBoundary, .utc)
    }

    /// `usage_daily` is optional in the payload. Its absence must leave the
    /// authoritative slot empty so the ledger falls back to differencing polls,
    /// rather than being read as a published zero that erases the day.
    func testMissingDailyTotalLeavesTheAuthoritativeSlotEmpty() throws {
        let key = try decodeKey(#"{"data":{"limit":null,"limit_reset":null,"usage":9,"is_free_tier":true}}"#)

        let observation = OpenRouterService.observation(key: key.data, at: date(2026, 7, 13))

        XCTAssertEqual(observation.runningTotal, 9)
        XCTAssertNil(observation.authoritativeDailyTotal)
    }

    /// The running total and the published daily total must describe the same
    /// scope, or the delta path and the authoritative path contradict each other
    /// on alternating polls. Both are key-scoped, so the account-wide
    /// `total_usage` from `/credits` is deliberately not the counter.
    func testObservationUsesKeyScopedUsageNotAccountWideCredits() throws {
        let credits = try decodeCredits(#"{"data":{"total_credits":100,"total_usage":80}}"#)
        let key = try decodeKey(#"{"data":{"limit":null,"limit_reset":null,"usage":12,"usage_daily":2}}"#)

        let observation = OpenRouterService.observation(key: key.data, at: date(2026, 7, 13))

        XCTAssertEqual(observation.runningTotal, 12)
        XCTAssertNotEqual(observation.runningTotal, credits.data.totalUsage)
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
