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

    // MARK: - Helpers

    private func observation(
        _ provider: ServiceType,
        unit: ProviderUsageUnit,
        total: Double,
        at date: Date
    ) -> ProviderUsageObservation {
        ProviderUsageObservation(provider: provider, unit: unit, runningTotal: total, observedAt: date)
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
