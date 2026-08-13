import MeterBarShared
import XCTest
@testable import MeterBar

/// Covers the bucketing behind the hover panel's seven-day sparkline.
///
/// The panel is provider-scoped, so every assertion here is about what the
/// series is allowed to *claim* for one provider: which days land in the
/// window, which rows belong to it, and — for the poll-and-accumulate
/// providers — which days it has no right to report at all.
///
/// Pixels are deliberately out of scope. The value of this chart is that the
/// seven numbers under the bars are the right seven numbers; the drawing is
/// covered by the panel layout tests.
final class ProviderDailyUsageSeriesTests: XCTestCase {
    // Pinned so the window arithmetic is reproducible: a run that straddles
    // local midnight would otherwise shift every bucket by a day.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// `offset` days from the start of `now`'s day. Negative is the past.
    private func day(_ offset: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private func tokenRow(
        _ offset: Int,
        provider: ServiceType = .claudeCode,
        tokens: Int,
        costUSD: Double = 0
    ) -> DailyTokenUsage {
        DailyTokenUsage(
            date: day(offset).addingTimeInterval(3600 * 9),
            provider: provider,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: costUSD
        )
    }

    private func tokenSeries(
        _ rows: [DailyTokenUsage],
        service: ServiceType = .claudeCode,
        accountCount: Int = 1
    ) -> ProviderDailyUsageSeries {
        ProviderDailyUsageSeries(
            service: service,
            dailyUsage: rows,
            accountCount: accountCount,
            dayCount: 7,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Window boundaries

    /// Seven buckets, oldest first, ending on today. The panel draws one bar
    /// per element without re-checking the count, so a short array would draw
    /// a short week rather than a gap.
    func testSeriesAlwaysCoversExactlySevenTrailingDays() {
        let series = tokenSeries([tokenRow(0, tokens: 100)])

        XCTAssertEqual(series.days.count, 7)
        XCTAssertEqual(series.days.first?.date, day(-6))
        XCTAssertEqual(series.days.last?.date, day(0))
        XCTAssertEqual(series.days.map(\.date), (-6...0).map { day($0) })
    }

    /// The seventh day back is outside the window. Folding it into the oldest
    /// bar is the classic off-by-one here, and it inflates exactly the bar a
    /// reader uses as their baseline.
    func testRowsOlderThanTheWindowAreExcluded() {
        let series = tokenSeries([
            tokenRow(-7, tokens: 999_999),
            tokenRow(-6, tokens: 10)
        ])

        XCTAssertEqual(series.days.first?.value, 10)
        XCTAssertEqual(series.totalValue, 10)
    }

    /// A cache written on a machine whose clock ran ahead can carry rows dated
    /// after today. They have no bar to land in, so they must not be counted
    /// into the total either — the total would then disagree with the bars.
    func testFutureDatedRowsAreIgnored() {
        let series = tokenSeries([
            tokenRow(1, tokens: 500),
            tokenRow(0, tokens: 25)
        ])

        XCTAssertEqual(series.days.last?.value, 25)
        XCTAssertEqual(series.totalValue, 25)
    }

    // MARK: - Provider scoping

    /// The panel opens from one provider's card. Summing the whole cache here
    /// would show Codex's week under Claude's header.
    func testOtherProvidersAreExcluded() {
        let series = tokenSeries([
            tokenRow(-1, provider: .claudeCode, tokens: 30),
            tokenRow(-1, provider: .codexCli, tokens: 4000),
            tokenRow(0, provider: .grok, tokens: 4000)
        ])

        XCTAssertEqual(series.totalValue, 30)
        XCTAssertEqual(series.days.last?.value, 0)
    }

    /// Scanners emit one row per day *per source file*, so a single day can
    /// arrive as several rows.
    func testMultipleRowsForOneDayAreSummed() {
        let series = tokenSeries([
            tokenRow(-2, tokens: 100),
            tokenRow(-2, tokens: 250)
        ])

        XCTAssertEqual(series.days[4].value, 350)
    }

    // MARK: - Sparse and empty history

    /// A quiet day is a measured zero for the token providers: the scan re-reads
    /// the log files, so silence is evidence, not absence.
    func testSparseDaysFillAsMeasuredZeros() {
        let series = tokenSeries([tokenRow(-3, tokens: 60)])

        XCTAssertEqual(series.days.map(\.value), [0, 0, 0, 60, 0, 0, 0])
        XCTAssertTrue(series.days.allSatisfy(\.isMeasured))
        XCTAssertTrue(series.hasHistory)
    }

    /// Before the first scan there is nothing to draw, and the panel shows an
    /// empty state instead of seven flat bars that read as a quiet week.
    func testEmptyInputHasNoHistory() {
        let series = tokenSeries([])

        XCTAssertEqual(series.days.count, 7)
        XCTAssertFalse(series.hasHistory)
        XCTAssertEqual(series.totalValue, 0)
        XCTAssertEqual(series.peakValue, 0)
    }

    /// The bars are scaled against the tallest day, so the peak has to come
    /// from the window rather than from the whole cache.
    func testPeakIsTheTallestDayInTheWindow() {
        let series = tokenSeries([
            tokenRow(-8, tokens: 1_000_000),
            tokenRow(-4, tokens: 700),
            tokenRow(0, tokens: 120)
        ])

        XCTAssertEqual(series.peakValue, 700)
    }

    // MARK: - Units

    func testTokenProvidersAreDenominatedInTokens() {
        XCTAssertEqual(tokenSeries([], service: .claudeCode).metric, .tokens)
    }

    /// Cursor publishes a request counter with no currency field anywhere in
    /// the payload, so its series must never be labelled or formatted as money.
    func testCursorLedgerSeriesIsDenominatedInRequests() {
        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 0,
                observedAt: day(-4)
            ),
            calendar: calendar
        )
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 12,
                observedAt: day(-2)
            ),
            calendar: calendar
        )

        let series = ProviderDailyUsageSeries(
            service: .cursor,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(series.metric, .requests)
        XCTAssertEqual(series.days[4].value, 12)
        XCTAssertEqual(series.totalValue, 12)
    }

    func testOpenRouterLedgerSeriesIsDenominatedInDollars() {
        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .openRouter,
                unit: .usd,
                runningTotal: 4,
                authoritativeDailyTotal: 1.5,
                dayBoundary: .utc,
                observedAt: day(-1)
            ),
            calendar: calendar
        )

        let series = ProviderDailyUsageSeries(
            service: .openRouter,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(series.metric, .usd)
        XCTAssertEqual(series.days[5].value, 1.5, accuracy: 0.0001)
    }

    // MARK: - Coverage

    /// The ledger is a poll-and-accumulate series with no backfill, so days
    /// before the first poll were never observed. Drawing them as zero would
    /// claim MeterBar watched a week it did not.
    func testLedgerDaysBeforeTheFirstPollAreUnmeasured() {
        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 3,
                observedAt: day(-2)
            ),
            calendar: calendar
        )

        let series = ProviderDailyUsageSeries(
            service: .cursor,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(series.days.map(\.isMeasured), [false, false, false, false, true, true, true])
        XCTAssertEqual(series.coverageStart, day(-2))
    }

    /// A provider MeterBar has never polled has no series at all, which is a
    /// different empty state from "polled, and the week was quiet".
    func testLedgerWithoutAnEntryHasNoHistory() {
        let series = ProviderDailyUsageSeries(
            service: .cursor,
            ledger: ProviderUsageLedger(),
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertFalse(series.hasHistory)
        XCTAssertNil(series.coverageStart)
        XCTAssertTrue(series.days.allSatisfy { !$0.isMeasured })
    }

    // MARK: - Accounts

    /// `DailyTokenUsage` carries no account dimension, but the popover shows one
    /// card per Claude/Codex/Grok account. The series has to admit that its
    /// numbers cover every account, not just the hovered card's.
    func testMultipleAccountsMarkTheSeriesAsCombined() {
        XCTAssertTrue(tokenSeries([], accountCount: 2).isCombinedAcrossAccounts)
        XCTAssertFalse(tokenSeries([], accountCount: 1).isCombinedAcrossAccounts)
        XCTAssertFalse(tokenSeries([], accountCount: 0).isCombinedAcrossAccounts)
    }

    /// Cursor and OpenRouter are single-account providers, and their ledger is
    /// account-blind by construction, so the caption never applies to them.
    func testLedgerSeriesIsNeverMarkedCombined() {
        let series = ProviderDailyUsageSeries(
            service: .openRouter,
            ledger: ProviderUsageLedger(),
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertFalse(series.isCombinedAcrossAccounts)
    }

    // MARK: - Source selection

    /// The front door the popover uses. Picking the wrong source is silent:
    /// Cursor has no token rows, so a token-sourced Cursor series would be a
    /// permanently empty chart telling the user to run a scan that can never
    /// populate it.
    func testSourceIsChosenFromWhereTheProviderKeepsItsHistory() {
        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 5,
                observedAt: day(-1)
            ),
            calendar: calendar
        )

        let cursor = ProviderDailyUsageSeries.make(
            service: .cursor,
            dailyUsage: [tokenRow(-1, provider: .claudeCode, tokens: 900)],
            ledger: ledger,
            accountCount: 1,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(cursor.metric, .requests)

        let claude = ProviderDailyUsageSeries.make(
            service: .claudeCode,
            dailyUsage: [tokenRow(-1, provider: .claudeCode, tokens: 900)],
            ledger: ledger,
            accountCount: 1,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(claude.metric, .tokens)
        XCTAssertEqual(claude.totalValue, 900)
    }

    /// Which providers write local session logs is a fact about the provider,
    /// not about the chart — it decides the source here and the empty-state
    /// copy in the panel, so both read it from the same place.
    func testOnlyLogWritingProvidersReportLocalTokenHistory() {
        XCTAssertTrue(ServiceType.claudeCode.writesLocalTokenLogs)
        XCTAssertTrue(ServiceType.codexCli.writesLocalTokenLogs)
        XCTAssertTrue(ServiceType.grok.writesLocalTokenLogs)
        XCTAssertFalse(ServiceType.cursor.writesLocalTokenLogs)
        XCTAssertFalse(ServiceType.openRouter.writesLocalTokenLogs)
    }

    func testRequestHeaderTotalDoesNotRepeatTheUnitNoun() {
        var ledger = ProviderUsageLedger()
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 10,
                observedAt: day(-1)
            ),
            calendar: calendar
        )
        ledger.record(
            ProviderUsageObservation(
                provider: .cursor,
                unit: .requests,
                runningTotal: 31_268,
                observedAt: day(0)
            ),
            calendar: calendar
        )

        let series = ProviderDailyUsageSeries(
            service: .cursor,
            ledger: ledger,
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(series.formattedTotal, "31258 requests")
        XCTAssertEqual(series.headerTotalText, "31258 requests")
        XCTAssertFalse(series.headerTotalText.contains("requests requests"))
    }

    func testTokenHeaderTotalKeepsTheUnitNoun() {
        let series = tokenSeries([tokenRow(0, tokens: 1_200)])

        XCTAssertEqual(series.headerTotalText, "\(series.formattedTotal) tokens")
        XCTAssertTrue(series.headerTotalText.hasSuffix("tokens"))
    }
}
