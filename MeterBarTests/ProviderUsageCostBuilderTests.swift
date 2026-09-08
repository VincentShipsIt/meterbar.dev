import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Coverage for the one path from the poll ledger into money.
///
/// `costs[]` and `dailyUsage[]` are denominated in dollars and tokens. Cursor's
/// counter is neither — it is a count of requests against a plan allowance, with
/// no rate published anywhere to convert it. These tests pin the boundary: what
/// the ledger is allowed to claim, and what it must refuse to claim.
final class ProviderUsageCostBuilderTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Units

    /// The load-bearing test of the whole change. Cursor's usage-summary payload
    /// carries no currency field at all, so a dollar figure derived from
    /// `plan.used` would be invented rather than measured. The builder must emit
    /// nothing for it — not a zero row, not a converted one.
    func testRequestDenominatedProviderProducesNoCostRowAtAll() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 40, at: day(0)))
        ledger.record(observation(.cursor, unit: .requests, total: 190, at: day(1)))

        XCTAssertNil(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .cursor, windowStart: day(-30), now: day(1))
        )
    }

    /// A request series still exists and is still readable — it is only barred
    /// from the dollar fold. Losing it entirely would trade one wrong number for
    /// no number.
    func testRequestDenominatedProviderKeepsItsOwnSeries() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.cursor, unit: .requests, total: 40, at: day(0)))
        ledger.record(observation(.cursor, unit: .requests, total: 190, at: day(1)))

        XCTAssertEqual(ledger.dailySeries(for: .cursor).map(\.amount), [150])
        XCTAssertTrue(ledger.dailyUSDSeries(for: .cursor).isEmpty)
        XCTAssertEqual(ledger.usdProviders, [])
        XCTAssertEqual(ledger.nonUSDProviders, [.cursor])
    }

    // MARK: - Dollar-denominated rows

    func testDollarDenominatedProviderProducesOneCostAndOneRowPerDay() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 10, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 12, at: day(1)))
        ledger.record(observation(.openRouter, unit: .usd, total: 15.5, at: day(2)))

        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(2))
        )

        XCTAssertEqual(built.0.provider, .openRouter)
        XCTAssertEqual(built.0.estimatedCostUSD, 5.5, accuracy: 0.000_001)
        XCTAssertEqual(built.0.periodStart, day(1))
        XCTAssertEqual(built.0.periodEnd, day(2))
        XCTAssertEqual(built.1.map(\.date), [day(1), day(2)])
        XCTAssertEqual(built.1.map(\.estimatedCostUSD), [2, 3.5])
        XCTAssertTrue(built.2.isEmpty, "poll-only providers have no event timestamp for hourly bucketing")
    }

    /// OpenRouter's key endpoint reports spend and no token counts whatsoever.
    /// Zero states that plainly; any other figure would be fabricated, and a
    /// fabricated token count would flow straight into the headline "tokens"
    /// number on the dashboard.
    func testNoTokenCountsAreInventedForAProviderThatReportsNone() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 1, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 4, at: day(1)))

        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(1))
        )

        XCTAssertEqual(built.0.totalTokens, 0)
        XCTAssertEqual(built.0.sessionCount, 0)
        XCTAssertEqual(built.1.map(\.inputTokens), [0])
        XCTAssertEqual(built.1.map(\.outputTokens), [0])
    }

    /// Breakdowns must be empty arrays, never `nil`. `nil` means "this row
    /// predates attribution" to `needsMissingDailyUsageRefresh`, which would
    /// kick off a full corpus re-scan on every single Costs view open, forever —
    /// and no re-scan can ever fill them, because there is no corpus.
    func testEmptyBreakdownsDoNotTriggerAPerpetualRescan() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 1, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 4, at: day(1)))

        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(1))
        )
        for row in built.1 {
            XCTAssertEqual(row.modelBreakdowns?.count, 0)
            XCTAssertEqual(row.projectBreakdowns?.count, 0)
            XCTAssertEqual(row.sessionBreakdowns?.count, 0)
        }

        let summary = CostSummary(
            costs: [built.0],
            totalCostUSD: built.0.estimatedCostUSD,
            totalTokens: built.0.totalTokens,
            periodDays: 30,
            dailyUsage: built.1
        )
        XCTAssertFalse(summary.needsMissingDailyUsageRefresh(days: 30, lastScanDate: day(1)))
    }

    // MARK: - Window boundaries

    /// The 30-day window must not drag the whole retained history into the
    /// period totals just because these rows arrive outside the scanners.
    func testDaysOutsideTheWindowAreExcluded() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 0, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)))
        ledger.record(observation(.openRouter, unit: .usd, total: 103, at: day(40)))

        let period = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(11), now: day(40))
        )
        XCTAssertEqual(period.0.estimatedCostUSD, 3, accuracy: 0.000_001)

        let lifetime = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(
                from: ledger,
                provider: .openRouter,
                windowStart: .distantPast,
                now: day(40)
            )
        )
        XCTAssertEqual(lifetime.0.estimatedCostUSD, 103, accuracy: 0.000_001)
    }

    /// A provider that has never been polled has no history to report, and the
    /// absence must stay an absence: a zero-dollar `TokenCost` would put an
    /// empty provider row on the dashboard claiming a measured $0.00.
    func testNeverObservedProviderContributesNothing() {
        let ledger = ProviderUsageLedger()

        XCTAssertNil(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(0))
        )
    }

    /// The first poll is a baseline only, so a freshly installed app shows no
    /// OpenRouter row rather than a spike equal to the user's lifetime spend.
    func testFirstPollAloneContributesNothing() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 812.44, at: day(0)))

        XCTAssertNil(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(0))
        )
    }

    /// If the clock moves backwards, a stored day can end up ahead of "today".
    /// Drawing it would put a bar off the right edge of the chart.
    func testFutureDatedDaysAreExcluded() throws {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 1, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 3, at: day(1)))
        ledger.record(observation(.openRouter, unit: .usd, total: 99, at: day(5)))

        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(from: ledger, provider: .openRouter, windowStart: day(-30), now: day(1))
        )
        XCTAssertEqual(built.1.map(\.date), [day(1)])
        XCTAssertEqual(built.0.estimatedCostUSD, 2, accuracy: 0.000_001)
    }

    // MARK: - The fold into the published summary

    /// End-to-end through the same builder `CostTracker` calls: a dollar
    /// provider reaches `costs[]`/`dailyUsage[]`, and a request provider in the
    /// very same ledger does not.
    func testMakeScanFoldsDollarProvidersAndSkipsRequestProviders() {
        var ledger = ProviderUsageLedger()
        ledger.record(observation(.openRouter, unit: .usd, total: 2, at: day(0)))
        ledger.record(observation(.openRouter, unit: .usd, total: 6, at: day(1)))
        ledger.record(observation(.cursor, unit: .requests, total: 10, at: day(0)))
        ledger.record(observation(.cursor, unit: .requests, total: 300, at: day(1)))

        let scan = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [],
            claudeAccounts: [],
            grokAccounts: [],
            session: CostScanSession(cutoff: day(-30), options: .unlimited),
            usageLedger: ledger
        )

        XCTAssertEqual(scan.summary.costs.map(\.provider), [.openRouter])
        XCTAssertEqual(scan.summary.totalCostUSD, 4, accuracy: 0.000_001)
        XCTAssertEqual(scan.summary.totalTokens, 0)
        XCTAssertEqual(scan.summary.dailyUsage.map(\.provider), [.openRouter])
        XCTAssertNil(scan.summary.lifetime)
    }

    /// The default keeps every existing call site — and the scanners' own
    /// tests — producing exactly what they did before the ledger existed.
    func testMakeScanWithoutALedgerProducesNoPolledRows() {
        let scan = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [],
            claudeAccounts: [],
            grokAccounts: [],
            session: CostScanSession(cutoff: day(-30), options: .unlimited)
        )

        XCTAssertTrue(scan.summary.costs.isEmpty)
        XCTAssertTrue(scan.summary.dailyUsage.isEmpty)
    }

    // MARK: - Day boundary (issue #543)

    /// East of UTC (Berlin, UTC+2): local "today" trails the UTC bucket key by
    /// up to 22 hours, so windowing against the *local* calendar makes the
    /// "clock moved backwards" guard (`$0.date <= today`) discard today's
    /// legitimately UTC-keyed row for most of the day — a user spending
    /// $12.40/day on OpenRouter sees $0.00. The fix windows each provider
    /// against its own `dayBoundary`, matching `ProviderDailyUsageSeries`.
    func testUTCKeyedTodayIsNotDroppedEastOfUTC() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(secondsFromGMT: 2 * 3_600) ?? .gmt

        // 2026-09-08 00:00 UTC and 2026-09-07 00:00 UTC — the ledger's own
        // bucket keys, independent of any calendar under test.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let day7UTC = utc.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        let day8UTC = utc.date(from: DateComponents(year: 2026, month: 9, day: 8))!

        var ledger = ProviderUsageLedger()
        // Baseline poll: contributes nothing on its own (issue-unrelated rule).
        ledger.record(utcObservation(total: 10, at: day7UTC.addingTimeInterval(3_600 * 12)), calendar: berlin)
        // Delta of 5 lands in the Sept 7 UTC bucket.
        ledger.record(utcObservation(total: 15, at: day7UTC.addingTimeInterval(3_600 * 20)), calendar: berlin)
        // Delta of 7.4 lands in the Sept 8 UTC bucket — observed at 08:00 UTC,
        // which is 10:00 local in Berlin: well inside the ~22-hour window the
        // bug zeroed out.
        ledger.record(utcObservation(total: 22.4, at: day8UTC.addingTimeInterval(3_600 * 8)), calendar: berlin)

        let now = day8UTC.addingTimeInterval(3_600 * 8)
        let windowStart = day7UTC.addingTimeInterval(-3_600 * 24 * 28)
        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(
                from: ledger,
                provider: .openRouter,
                windowStart: windowStart,
                now: now,
                calendar: berlin
            )
        )

        XCTAssertEqual(built.1.map(\.date), [day7UTC, day8UTC], "today's UTC-keyed row must not be dropped")
        XCTAssertEqual(built.0.estimatedCostUSD, 12.4, accuracy: 0.000_001)
        XCTAssertEqual(built.0.periodEnd, day8UTC)
    }

    /// West of UTC (Los Angeles, UTC-7): a UTC-keyed day's bucket instant sits
    /// *before* the local calendar's start-of-day for the "same" nominal date,
    /// so windowing against the local calendar drops the oldest UTC-keyed day
    /// from every window — on the 1st of the month this reads Month-to-Date
    /// OpenRouter spend as $0.00 all day (issue #543).
    func testUTCKeyedOldestDayIsNotDroppedWestOfUTC() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(secondsFromGMT: -7 * 3_600) ?? .gmt

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let day1UTC = utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let day2UTC = utc.date(from: DateComponents(year: 2026, month: 9, day: 2))!

        var ledger = ProviderUsageLedger()
        // Baseline poll, before the window: contributes nothing on its own.
        ledger.record(
            utcObservation(total: 0, at: day1UTC.addingTimeInterval(-3_600 * 6)),
            calendar: losAngeles
        )
        // Delta of 1 lands in the Sept 1 UTC bucket — the oldest day in the
        // window below.
        ledger.record(utcObservation(total: 1, at: day1UTC.addingTimeInterval(3_600 * 6)), calendar: losAngeles)
        // Delta of 3 lands in the Sept 2 UTC bucket.
        ledger.record(utcObservation(total: 4, at: day2UTC.addingTimeInterval(3_600 * 6)), calendar: losAngeles)

        // The window starts exactly at the local calendar's midnight for
        // "September 1st" — 2026-09-01T00:00:00 in Los Angeles, seven hours
        // *after* the UTC bucket key for that same nominal day. `now` sits
        // solidly inside Sept 2 local (13:00) so only the start-of-window
        // comparison is under test here, not the "today" guard.
        let windowStart = losAngeles.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let now = day2UTC.addingTimeInterval(3_600 * 20)

        let built = try XCTUnwrap(
            ProviderUsageCostBuilder.makeCost(
                from: ledger,
                provider: .openRouter,
                windowStart: windowStart,
                now: now,
                calendar: losAngeles
            )
        )

        XCTAssertEqual(built.1.map(\.date), [day1UTC, day2UTC], "the oldest UTC-keyed day must not be dropped")
        XCTAssertEqual(built.0.estimatedCostUSD, 4, accuracy: 0.000_001)
    }

    // MARK: - Helpers

    private func observation(
        _ provider: ServiceType,
        unit: ProviderUsageUnit,
        total: Double,
        at date: Date
    ) -> ProviderUsageObservation {
        ProviderUsageObservation(provider: provider, unit: unit, runningTotal: total, observedAt: date)
    }

    private func utcObservation(total: Double, at date: Date) -> ProviderUsageObservation {
        ProviderUsageObservation(
            provider: .openRouter,
            unit: .usd,
            runningTotal: total,
            dayBoundary: .utc,
            observedAt: date
        )
    }

    /// Start of the day `offset` days after a fixed epoch.
    private func day(_ offset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        components.hour = 12
        let base = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let shifted = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        return calendar.startOfDay(for: shifted)
    }
}
