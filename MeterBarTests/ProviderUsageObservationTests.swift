import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Unit tests for `ProviderUsageLedger` — the poll-and-accumulate series for the
/// two providers that keep no local session log (issue: Cursor and OpenRouter
/// contributed no `costs[]`/`dailyUsage[]` rows at all, so they were
/// structurally absent from the spend chart, the dashboard cost section, and the
/// share card).
///
/// Neither provider reports per-session usage. Both report a *running counter*
/// that MeterBar has to differentiate into a dated series, and every load-bearing
/// fact here is about that conversion: which day a delta belongs to, what a
/// counter going backwards means, which figure wins when the provider publishes
/// its own daily total, and — most of all — what the series is not allowed to
/// claim about days it never observed. Getting any one wrong produces a
/// plausible-looking number that is simply false.
final class ProviderUsageObservationTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Baseline and backfill

    /// The first poll establishes a baseline and nothing else.
    ///
    /// OpenRouter's `usage` is a *lifetime* total. Treating the first reading as
    /// a delta against zero would land a user's entire account history — possibly
    /// hundreds of dollars accrued over a year — on the single day they installed
    /// MeterBar, and that spike would then anchor the chart's y-axis forever.
    func testFirstObservationEstablishesABaselineWithoutEmittingARow() {
        var ledger = ProviderUsageLedger()

        ledger.record(
            observation(.openRouter, unit: .usd, total: 412.50, at: day(1)),
            calendar: calendar
        )

        XCTAssertEqual(ledger.dailySeries(for: .openRouter), [])
    }

    /// Days before the first poll must be absent from the series, not zero.
    ///
    /// A zero row is an affirmative claim that nothing was spent that day. For a
    /// day MeterBar was not running, that claim is false — and `CostChartPresentation`
    /// draws a covered zero differently from an uncovered gap, so a fabricated
    /// zero would render as a confirmed quiet day.
    func testDaysBeforeTheFirstObservationAreAbsentRatherThanZero() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 10, at: day(5)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 13, at: day(6)), calendar: calendar)

        let dates = ledger.dailySeries(for: .openRouter).map(\.date)
        XCTAssertEqual(dates, [day(6)])
        XCTAssertEqual(ledger.firstObservedDate(for: .openRouter), day(5))
    }

    // MARK: - Delta attribution

    /// A delta belongs to the day the observation was taken.
    ///
    /// Attributing it to the *previous* observation's day — the other obvious
    /// reading of "spend between two polls" — back-dates every row by one poll
    /// interval and, across a midnight boundary, moves today's spend to
    /// yesterday.
    func testDeltaIsAttributedToTheObservationDayNotThePreviousObservationDay() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 107.25, at: day(2)), calendar: calendar)

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.date, day(2))
        XCTAssertEqual(series.first?.amount ?? 0, 7.25, accuracy: 1e-9)
    }

    /// Several polls on one day accumulate into that day's single row.
    ///
    /// Overwriting instead of summing would report only the last poll interval,
    /// silently discarding everything spent earlier in the day.
    func testMultiplePollsOnTheSameDayAccumulateIntoOneRow() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 101, at: day(2, hour: 9)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 104, at: day(2, hour: 17)), calendar: calendar)

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.amount ?? 0, 4, accuracy: 1e-9)
    }

    /// An unchanged counter emits no row at all.
    ///
    /// A zero-delta poll means "nothing new since last time", which is already
    /// expressed by the day's absence. Writing a `0` row would make an idle day
    /// indistinguishable from a day that was measured and confirmed empty, and
    /// would drag a meaningless entry into the "Daily Details" list.
    func testUnchangedCounterEmitsNoRowForThatDay() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(2)), calendar: calendar)

        XCTAssertEqual(ledger.dailySeries(for: .openRouter), [])
    }

    // MARK: - Counter resets

    /// A counter that drops is a reset, not negative spend.
    ///
    /// Cursor's `plan.used` zeroes at `billingCycleStart`. Subtracting the old
    /// baseline would emit a large negative row that cancels out real earlier
    /// spend, making a month-boundary refresh *reduce* the reported total.
    func testDroppingCounterIsTreatedAsAResetAndNeverEmitsANegativeRow() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.cursor, unit: .requests, total: 480, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 12, at: day(2)), calendar: calendar)

        let series = ledger.dailySeries(for: .cursor)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.date, day(2))
        XCTAssertEqual(series.first?.amount ?? 0, 12, accuracy: 1e-9)
        XCTAssertFalse(series.contains { $0.amount < 0 })
    }

    /// After a reset the post-reset value is the day's contribution, and the new
    /// baseline is the post-reset counter.
    ///
    /// Leaving the pre-reset baseline in place would swallow the whole next
    /// cycle: every reading below the old high-water mark would keep re-reading
    /// as another reset, and the series would repeat the running total instead
    /// of differentiating it.
    func testBaselineFollowsThePostResetCounterSoTheNextDeltaIsCorrect() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.cursor, unit: .requests, total: 480, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 12, at: day(2)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 30, at: day(3)), calendar: calendar)

        let series = ledger.dailySeries(for: .cursor)
        XCTAssertEqual(series.map(\.date), [day(2), day(3)])
        XCTAssertEqual(series.last?.amount ?? 0, 18, accuracy: 1e-9)
    }

    /// Spend across a billing-cycle reset is conserved, not double-counted.
    ///
    /// Treating the post-reset value as a delta against zero is only correct
    /// because the pre-reset consumption was already attributed on earlier days.
    /// This pins the arithmetic end to end so a "fix" that also re-adds the
    /// pre-reset high-water mark fails here.
    func testTotalAcrossAResetEqualsTheSumOfBothCycles() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.cursor, unit: .requests, total: 0, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 200, at: day(2)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 500, at: day(3)), calendar: calendar)
        // Cycle rolls over: the counter zeroes and climbs again.
        ledger.record(observation(.cursor, unit: .requests, total: 40, at: day(4)), calendar: calendar)

        let total = ledger.dailySeries(for: .cursor).reduce(0) { $0 + $1.amount }
        XCTAssertEqual(total, 540, accuracy: 1e-9)
    }

    // MARK: - Provider-published daily totals

    /// OpenRouter's own `usage_daily` wins over the computed delta for today.
    ///
    /// The delta only knows what happened between two polls. `usage_daily` is
    /// the provider's figure for the whole calendar day, so preferring it is
    /// what lets a day survive a laptop that was asleep for most of it.
    func testAuthoritativeDailyTotalOverridesTheComputedDeltaForToday() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 102, authoritativeDaily: 9.5, at: day(2)),
            calendar: calendar
        )

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.amount ?? 0, 9.5, accuracy: 1e-9)
    }

    /// Applying `usage_daily` must not also apply that poll's delta.
    ///
    /// Adding both is the natural implementation slip — record the delta, then
    /// "correct" the row — and it inflates every day the provider publishes a
    /// total by exactly one poll interval.
    func testAuthoritativeDailyTotalIsNotAddedOnTopOfTheDelta() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 105, authoritativeDaily: 5, at: day(2)),
            calendar: calendar
        )

        XCTAssertEqual(ledger.dailySeries(for: .openRouter).first?.amount ?? 0, 5, accuracy: 1e-9)
    }

    /// A later `usage_daily` replaces an earlier delta-derived row for the same
    /// day rather than adding to it.
    ///
    /// This is the self-heal path: the morning poll had no published total and
    /// fell back to a delta; the evening poll has one and is authoritative. Summing
    /// would count the morning twice.
    func testAuthoritativeDailyTotalReplacesAnEarlierDeltaRowForTheSameDay() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 103, at: day(2, hour: 9)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 108, authoritativeDaily: 8, at: day(2, hour: 21)),
            calendar: calendar
        )

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.amount ?? 0, 8, accuracy: 1e-9)
    }

    /// After an authoritative poll the running baseline still advances.
    ///
    /// `usage_daily` is optional in OpenRouter's payload. If the field goes away
    /// on the next poll, the delta path resumes — and it resumes against a stale
    /// baseline unless the authoritative branch re-baselines too, re-charging
    /// every dollar since the last non-authoritative poll.
    func testAuthoritativePollStillRebaselinesSoALaterDeltaIsNotInflated() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 110, authoritativeDaily: 10, at: day(2)),
            calendar: calendar
        )
        ledger.record(observation(.openRouter, unit: .usd, total: 112, at: day(3)), calendar: calendar)

        XCTAssertEqual(ledger.dailySeries(for: .openRouter).last?.amount ?? 0, 2, accuracy: 1e-9)
    }

    /// A published daily total of zero clears the day instead of writing `0`.
    ///
    /// The provider saying "nothing today" is still not a reason to persist a
    /// zero row — the day's absence already says that, and a stored zero would
    /// leak into the "Daily Details" list as an empty entry.
    func testZeroAuthoritativeDailyTotalRemovesTheRowRatherThanStoringZero() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 103, at: day(2, hour: 9)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 103, authoritativeDaily: 0, at: day(2, hour: 21)),
            calendar: calendar
        )

        XCTAssertEqual(ledger.dailySeries(for: .openRouter), [])
    }

    /// The very first poll may still use its published daily total.
    ///
    /// `usage_daily` claims only today, so unlike the lifetime `usage` scalar it
    /// is not a backfill and does not violate the no-history rule. Suppressing
    /// it would throw away the one real figure available on install day.
    func testFirstObservationMayUseItsPublishedDailyTotal() {
        var ledger = ProviderUsageLedger()

        ledger.record(
            observation(.openRouter, unit: .usd, total: 412.50, authoritativeDaily: 3.25, at: day(1)),
            calendar: calendar
        )

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.amount ?? 0, 3.25, accuracy: 1e-9)
    }

    // MARK: - Units

    /// Providers are accumulated independently and keep their own unit.
    ///
    /// Cursor counts requests and OpenRouter counts dollars. A shared bucket, or
    /// a series that forgets which unit it is in, is exactly how a request count
    /// ends up rendered with a dollar sign.
    func testEachProviderKeepsItsOwnUnitAndSeries() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 10, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 12, at: day(2)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 140, at: day(2)), calendar: calendar)

        XCTAssertEqual(ledger.unit(for: .openRouter), .usd)
        XCTAssertEqual(ledger.unit(for: .cursor), .requests)
        XCTAssertEqual(ledger.dailySeries(for: .openRouter).first?.amount ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(ledger.dailySeries(for: .cursor).first?.amount ?? 0, 40, accuracy: 1e-9)
    }

    /// Only dollar-denominated entries can produce cost rows.
    ///
    /// This is the guard against the single worst outcome available here:
    /// Cursor's request count reaching `estimatedCostUSD` and being printed as
    /// money. Cursor's usage-summary payload carries no currency field at all,
    /// so there is no rate to convert with and no honest dollar figure to emit.
    func testRequestDenominatedEntriesProduceNoUSDRows() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.cursor, unit: .requests, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .requests, total: 140, at: day(2)), calendar: calendar)

        XCTAssertEqual(ledger.dailyUSDSeries(for: .cursor), [])
        XCTAssertFalse(ledger.usdProviders.contains(.cursor))
        XCTAssertFalse(ledger.dailySeries(for: .cursor).isEmpty)
    }

    /// A provider whose reported unit changes starts a fresh baseline.
    ///
    /// Differencing a dollar figure against a request count would emit a number
    /// in neither unit. Dropping the stale baseline costs one poll interval;
    /// keeping it produces silent nonsense.
    func testUnitChangeRestartsTheBaselineInsteadOfDifferencingAcrossUnits() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.cursor, unit: .requests, total: 400, at: day(1)), calendar: calendar)
        ledger.record(observation(.cursor, unit: .usd, total: 5, at: day(2)), calendar: calendar)

        XCTAssertEqual(ledger.dailySeries(for: .cursor), [])
        XCTAssertEqual(ledger.unit(for: .cursor), .usd)
    }

    // MARK: - Malformed input

    /// Non-finite and negative readings are ignored, baseline included.
    ///
    /// A `NaN` reaching the baseline poisons every later comparison — `NaN >= x`
    /// is false, so every subsequent poll would read as a reset and re-charge the
    /// full running total, every time.
    func testNonFiniteOrNegativeReadingsAreIgnoredEntirely() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: .nan, at: day(2)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: -5, at: day(2)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 103, at: day(2)), calendar: calendar)

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.amount ?? 0, 3, accuracy: 1e-9)
    }

    /// A non-finite published daily total falls back to the delta.
    ///
    /// Storing it would make the day's amount `NaN`, and a `NaN` row propagates
    /// through every `reduce` in the cost summary until the headline total reads
    /// "$nan".
    func testNonFiniteAuthoritativeDailyTotalFallsBackToTheDelta() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 104, authoritativeDaily: .infinity, at: day(2)),
            calendar: calendar
        )

        XCTAssertEqual(ledger.dailySeries(for: .openRouter).first?.amount ?? 0, 4, accuracy: 1e-9)
    }

    /// An observation older than the last one recorded is dropped.
    ///
    /// A stale reading would re-baseline *downwards*, and the drop reads as a
    /// reset — so the next poll re-charges the entire running counter as one
    /// day's spend. Clock adjustments and out-of-order concurrent refreshes both
    /// produce this.
    func testObservationOlderThanTheLastRecordedOneIsDropped() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 100, at: day(1)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 150, at: day(5)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 120, at: day(3)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 155, at: day(6)), calendar: calendar)

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.map(\.date), [day(5), day(6)])
        XCTAssertEqual(series.last?.amount ?? 0, 5, accuracy: 1e-9)
    }

    // MARK: - Retention

    /// The ledger keeps a bounded window of days.
    ///
    /// This file is rewritten on every poll for the life of the install. Without
    /// a bound it grows without limit, and the store's own size guard would
    /// eventually start refusing writes — which silently freezes the baseline.
    func testDaysOlderThanTheRetentionWindowArePruned() {
        var ledger = ProviderUsageLedger()

        ledger.record(observation(.openRouter, unit: .usd, total: 10, at: day(0)), calendar: calendar)
        ledger.record(observation(.openRouter, unit: .usd, total: 20, at: day(1)), calendar: calendar)
        ledger.record(
            observation(.openRouter, unit: .usd, total: 30, at: day(ProviderUsageLedger.retainedDays + 5)),
            calendar: calendar
        )

        let series = ledger.dailySeries(for: .openRouter)
        XCTAssertEqual(series.map(\.date), [day(ProviderUsageLedger.retainedDays + 5)])
    }

    // MARK: - Helpers

    private func observation(
        _ provider: ServiceType,
        unit: ProviderUsageUnit,
        total: Double,
        authoritativeDaily: Double? = nil,
        at date: Date
    ) -> ProviderUsageObservation {
        ProviderUsageObservation(
            provider: provider,
            unit: unit,
            runningTotal: total,
            authoritativeDailyTotal: authoritativeDaily,
            observedAt: date
        )
    }

    /// Day `offset` after a fixed epoch, at `hour` local time.
    private func day(_ offset: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = hour
        let base = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let shifted = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        return hour == 12 ? calendar.startOfDay(for: shifted) : shifted
    }
}
