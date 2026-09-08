import XCTest
import MeterBarShared
@testable import MeterBar

/// Unit tests for `CostSummary.dailyCostWindow` — the pure filter behind
/// `meterbar cost --days N` (issue #26). Uses a fixed `now` + UTC calendar so
/// day-boundary math is deterministic.
final class CostWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A daily row `offset` days before `now` (0 = today).
    private func row(
        daysAgo offset: Int,
        provider: ServiceType,
        input: Int,
        output: Int,
        cacheRead: Int,
        cost: Double,
        modelBreakdowns: [TokenUsageBreakdown]? = nil,
        projectBreakdowns: [TokenUsageBreakdown]? = nil,
        sessionBreakdowns: [TokenUsageBreakdown]? = nil
    ) -> DailyTokenUsage {
        let today = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
        return DailyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost,
            modelBreakdowns: modelBreakdowns,
            projectBreakdowns: projectBreakdowns,
            sessionBreakdowns: sessionBreakdowns
        )
    }

    private func breakdown(
        name: String,
        provider: ServiceType = .claudeCode,
        input: Int,
        cost: Double,
        models: [TokenUsageBreakdown] = []
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: input,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: cost,
            sessionCount: 1,
            modelBreakdowns: models
        )
    }

    private func summary(dailyUsage: [DailyTokenUsage], periodDays: Int) -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: periodDays,
            dailyUsage: dailyUsage
        )
    }

    // MARK: - Window boundary

    func testKeepsOnlyRowsInsideTheWindow() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 10, output: 5, cacheRead: 1, cost: 1.0),
                row(daysAgo: 2, provider: .claudeCode, input: 20, output: 5, cacheRead: 1, cost: 2.0),
                row(daysAgo: 3, provider: .claudeCode, input: 99, output: 99, cacheRead: 99, cost: 9.0),
                row(daysAgo: 4, provider: .claudeCode, input: 99, output: 99, cacheRead: 99, cost: 9.0)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 3, now: now, calendar: calendar)

        // Only offsets 0..2 fall in a 3-day window (today + 2 prior days).
        let claude = window.providers.first { $0.provider == .claudeCode }
        XCTAssertEqual(window.providers.count, 1)
        XCTAssertEqual(claude?.inputTokens, 30)
        XCTAssertEqual(claude?.outputTokens, 10)
        XCTAssertEqual(claude?.cacheReadTokens, 2)
        XCTAssertEqual(claude?.estimatedCostUSD, 3.0)
        XCTAssertEqual(window.totalCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertEqual(window.totalTokens, 42)
        XCTAssertFalse(window.isTruncated)
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06,
    /// so `startOfDay(now)` on that day is 01:00, not 00:00 (00:00–01:00 does
    /// not exist). A day-stepping window built from that instant without
    /// re-normalizing every hop would preserve 01:00 for the earlier day too,
    /// so its rows would land outside the `>=` bound and a "3 day" total
    /// would silently cover only 2. The UTC fixtures above cannot exercise
    /// this — UTC never observes DST.
    func testKeepsOnlyRowsInsideTheWindowAcrossTheSantiagoMidnightTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let dstNow = ISO8601DateFormatter().date(from: "2026-09-06T13:00:00Z") ?? now

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let date = santiago.date(from: components) ?? dstNow
            return santiago.startOfDay(for: date)
        }

        XCTAssertEqual(santiago.component(.hour, from: exactDay(2026, 9, 6)), 1)

        let summary = summary(
            dailyUsage: [
                DailyTokenUsage(
                    date: exactDay(2026, 9, 6).addingTimeInterval(3600 * 2),
                    provider: .claudeCode,
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1.0
                ),
                DailyTokenUsage(
                    date: exactDay(2026, 9, 4).addingTimeInterval(3600 * 5),
                    provider: .claudeCode,
                    inputTokens: 20,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 2.0
                ),
                // One day before the 3-day window (today + 2 prior days).
                DailyTokenUsage(
                    date: exactDay(2026, 9, 3).addingTimeInterval(3600 * 5),
                    provider: .claudeCode,
                    inputTokens: 99,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 9.0
                ),
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 3, now: dstNow, calendar: santiago)

        let claude = window.providers.first { $0.provider == .claudeCode }
        XCTAssertEqual(claude?.inputTokens, 30)
        XCTAssertEqual(window.totalCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertFalse(window.isTruncated)
    }

    // MARK: - Aggregation across providers

    func testAggregatesPerProviderSortedByRawValue() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 10, output: 0, cacheRead: 0, cost: 1.0),
                row(daysAgo: 1, provider: .claudeCode, input: 5, output: 0, cacheRead: 0, cost: 0.5),
                row(daysAgo: 0, provider: .codexCli, input: 7, output: 0, cacheRead: 0, cost: 0.7)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertEqual(window.providers.count, 2)
        XCTAssertEqual(window.providers.map(\.provider), [.claudeCode, .codexCli])
        XCTAssertEqual(window.providers[0].inputTokens, 15)
        XCTAssertEqual(window.providers[1].inputTokens, 7)
    }

    // MARK: - Truncation notice

    func testFlagsTruncationWhenCacheSpansFewerDays() {
        // Coverage is the tighter of the scan width (periodDays: 2) and the
        // actual row span (today only → 1 day).
        let summary = summary(
            dailyUsage: [row(daysAgo: 0, provider: .claudeCode, input: 1, output: 1, cacheRead: 0, cost: 0.1)],
            periodDays: 2
        )

        let window = summary.dailyCostWindow(lastDays: 30, now: now, calendar: calendar)

        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.requestedDays, 30)
        XCTAssertEqual(window.coveredDays, 1)
    }

    func testFlagsTruncationWhenRowSpanIsShorterThanScanWindow() {
        // Production scenario: every scan requests 30 days (periodDays: 30),
        // but a fresh install only has 2 real days of rows. The old
        // periodDays-only derivation reported coveredDays == 30 here and the
        // CLI notice never fired.
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 5, output: 2, cacheRead: 0, cost: 0.5),
                row(daysAgo: 1, provider: .claudeCode, input: 7, output: 3, cacheRead: 0, cost: 0.7)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 30, now: now, calendar: calendar)

        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.coveredDays, 2)
    }

    func testDoesNotFlagTruncationWhenRowsSpanTheFullWindow() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 5, output: 2, cacheRead: 0, cost: 0.5),
                row(daysAgo: 6, provider: .claudeCode, input: 7, output: 3, cacheRead: 0, cost: 0.7)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertFalse(window.isTruncated)
        XCTAssertEqual(window.coveredDays, 7)
    }

    func testReportsZeroCoverageForEmptyCache() {
        let summary = summary(dailyUsage: [], periodDays: 30)

        let window = summary.dailyCostWindow(lastDays: 30, now: now, calendar: calendar)

        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.coveredDays, 0)
    }

    // MARK: - Clamping

    func testClampsNonPositiveDaysToOne() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 3, output: 0, cacheRead: 0, cost: 0.3),
                row(daysAgo: 1, provider: .claudeCode, input: 9, output: 0, cacheRead: 0, cost: 0.9)
            ],
            periodDays: 30
        )

        let window = summary.dailyCostWindow(lastDays: 0, now: now, calendar: calendar)

        // Clamped to a single day (today only) → excludes yesterday's 9.
        XCTAssertEqual(window.requestedDays, 1)
        XCTAssertEqual(window.providers.first?.inputTokens, 3)
    }

    // MARK: - Month to date (issue #270)

    /// `now` (1_750_000_000) is 2025-06-15T14:13:20Z — the 15th, so a
    /// month-to-date window should span 15 calendar days (the 1st through
    /// today, inclusive).
    func testMonthToDateCoversFirstOfMonthThroughToday() {
        let summary = summary(
            dailyUsage: [
                row(daysAgo: 0, provider: .claudeCode, input: 10, output: 5, cacheRead: 1, cost: 1.0),
                row(daysAgo: 14, provider: .claudeCode, input: 20, output: 5, cacheRead: 1, cost: 2.0),
                // The 1st of the prior month — 15 days back is the 31st of May,
                // one day before June 1st, so this row must fall outside the window.
                row(daysAgo: 15, provider: .claudeCode, input: 99, output: 99, cacheRead: 99, cost: 9.0)
            ],
            periodDays: 30
        )

        let window = summary.monthToDateCostWindow(now: now, calendar: calendar)

        XCTAssertEqual(window.requestedDays, 15)
        let claude = window.providers.first { $0.provider == .claudeCode }
        XCTAssertEqual(claude?.inputTokens, 30)
        XCTAssertEqual(window.totalCostUSD, 3.0, accuracy: 0.0001)
    }

    /// The boundary must be computed fresh from `now` on every call — never
    /// cached — so a caller that re-invokes this after midnight on the 1st
    /// sees the window reset to a single day, not still show the previous
    /// month's accumulated span.
    func testMonthToDateRollsOverOnTheFirstOfTheMonth() {
        // 2025-07-01T00:00:00Z — the 1st of the following month.
        var components = DateComponents()
        components.year = 2025
        components.month = 7
        components.day = 1
        let firstOfNextMonth = calendar.date(from: components) ?? now

        let summary = summary(
            dailyUsage: [
                DailyTokenUsage(
                    date: firstOfNextMonth,
                    provider: .claudeCode,
                    inputTokens: 7,
                    outputTokens: 2,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0.7
                ),
                // Last day of June — must not leak into July's month-to-date window.
                DailyTokenUsage(
                    date: calendar.date(byAdding: .day, value: -1, to: firstOfNextMonth) ?? firstOfNextMonth,
                    provider: .claudeCode,
                    inputTokens: 999,
                    outputTokens: 999,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 99.0
                )
            ],
            periodDays: 30
        )

        let window = summary.monthToDateCostWindow(now: firstOfNextMonth, calendar: calendar)

        XCTAssertEqual(window.requestedDays, 1)
        XCTAssertEqual(window.providers.first?.inputTokens, 7)
        XCTAssertEqual(window.totalCostUSD, 0.7, accuracy: 0.0001)
    }

    func testMonthToDateAggregatesProjectAndModelBreakdownsFromPartiallyCachedMonth() throws {
        let opusDay = breakdown(name: "claude-opus-5", input: 20, cost: 2)
        let fableDay = breakdown(name: "claude-fable-5", input: 10, cost: 1)
        let summary = summary(
            dailyUsage: [
                // June 10: the scan itself covers only seven days through
                // `now` (June 15 in the fixed fixture), so the month window is
                // explicitly partial even though an older fixture row exists.
                row(
                    daysAgo: 5,
                    provider: .claudeCode,
                    input: 20,
                    output: 0,
                    cacheRead: 0,
                    cost: 2,
                    modelBreakdowns: [opusDay],
                    projectBreakdowns: [
                        breakdown(name: "meterbardev", input: 20, cost: 2, models: [opusDay])
                    ]
                ),
                row(
                    daysAgo: 0,
                    provider: .claudeCode,
                    input: 10,
                    output: 0,
                    cacheRead: 0,
                    cost: 1,
                    modelBreakdowns: [fableDay],
                    projectBreakdowns: [
                        breakdown(name: "meterbardev", input: 10, cost: 1, models: [fableDay])
                    ]
                ),
                // May 31: cached, but outside the current month and therefore
                // excluded from both the provider total and its attribution.
                row(
                    daysAgo: 15,
                    provider: .claudeCode,
                    input: 999,
                    output: 0,
                    cacheRead: 0,
                    cost: 99,
                    modelBreakdowns: [breakdown(name: "legacy-model", input: 999, cost: 99)],
                    projectBreakdowns: [breakdown(name: "other-project", input: 999, cost: 99)]
                )
            ],
            periodDays: 7
        )

        let window = summary.monthToDateCostWindow(now: now, calendar: calendar)
        let provider = try XCTUnwrap(window.providers.first)
        let project = try XCTUnwrap(provider.projectBreakdowns?.first)

        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.requestedDays, 15)
        XCTAssertEqual(window.coveredDays, 7)
        XCTAssertEqual(provider.modelBreakdowns?.map(\.name), ["claude-opus-5", "claude-fable-5"])
        XCTAssertEqual(project.name, "meterbardev")
        XCTAssertEqual(project.inputTokens, 30)
        XCTAssertEqual(project.estimatedCostUSD, 3, accuracy: 0.0001)
        XCTAssertEqual(Set(project.modelBreakdowns.map(\.name)), ["claude-opus-5", "claude-fable-5"])
    }

    // MARK: - Provider day boundaries (issue #543)

    /// West of UTC (Los Angeles, UTC-7): re-normalizing a UTC-keyed row through
    /// the *local* calendar's `startOfDay` maps it onto the local calendar day
    /// before the one OpenRouter itself reports, so it can fall out of a window
    /// it legitimately belongs in. Windowing each row against its own provider
    /// boundary (matching `ProviderDailyUsageSeries`) fixes it.
    func testDailyCostWindowKeepsUTCKeyedOpenRouterRowsWestOfUTC() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(secondsFromGMT: -7 * 3_600) ?? .gmt
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt

        // Solidly the 2nd locally in Los Angeles.
        let now = losAngeles.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 13))!
        // OpenRouter's own UTC-midnight bucket key for "September 1st".
        let openRouterFirst = utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        // Claude's row for the same nominal day, dated at *local* midnight.
        let claudeFirst = losAngeles.date(from: DateComponents(year: 2026, month: 9, day: 1))!

        let summary = summary(
            dailyUsage: [
                DailyTokenUsage(
                    date: openRouterFirst,
                    provider: .openRouter,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 5.0
                ),
                DailyTokenUsage(
                    date: claudeFirst,
                    provider: .claudeCode,
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 1,
                    estimatedCostUSD: 1.0
                ),
            ],
            periodDays: 2
        )

        let window = summary.dailyCostWindow(lastDays: 2, now: now, calendar: losAngeles)

        let openRouter = try XCTUnwrap(window.providers.first { $0.provider == .openRouter })
        XCTAssertEqual(openRouter.estimatedCostUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(window.totalCostUSD, 6.0, accuracy: 0.0001)
    }

    /// The Month-to-Date read on the 31st of a 31-day month, west of UTC — the
    /// exact combination from issue #543 ("MTD OpenRouter spend reads $0.00 all
    /// day" on the 1st) and issue #544 (a 31-day month needs 31 covered days).
    /// `periodDays: 31` simulates the widened `CostWindow.scanWindowDays` scan.
    func testMonthToDateOnThe31stIncludesUTCKeyedFirstOfMonthWestOfUTC() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(secondsFromGMT: -7 * 3_600) ?? .gmt
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt

        let thirtyFirst = losAngeles.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let openRouterFirst = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let claudeThirtyFirst = losAngeles.date(from: DateComponents(year: 2026, month: 1, day: 31))!

        let summary = summary(
            dailyUsage: [
                DailyTokenUsage(
                    date: openRouterFirst,
                    provider: .openRouter,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 12.4
                ),
                DailyTokenUsage(
                    date: claudeThirtyFirst,
                    provider: .claudeCode,
                    inputTokens: 100,
                    outputTokens: 50,
                    cacheReadTokens: 5,
                    estimatedCostUSD: 2.0
                ),
            ],
            periodDays: 31
        )

        let window = summary.monthToDateCostWindow(now: thirtyFirst, calendar: losAngeles)

        XCTAssertEqual(window.requestedDays, 31)
        XCTAssertFalse(window.isTruncated)
        let openRouter = try XCTUnwrap(window.providers.first { $0.provider == .openRouter })
        XCTAssertEqual(openRouter.estimatedCostUSD, 12.4, accuracy: 0.0001, "the 1st must not read $0.00")
        XCTAssertEqual(window.totalCostUSD, 14.4, accuracy: 0.0001)
    }

    // MARK: - Token metric parity across windows (issue #544)

    /// A window request must not change what "tokens" means. The 30-day card
    /// reads `CostSummary.totalTokens` (cache-creation included); the 7-day and
    /// Month-to-Date cards used to read `ProviderDailyTotal.totalTokens`, which
    /// deliberately omits cache-creation for CLI schema compatibility — so a
    /// cache-heavy account's headline fell by an order of magnitude on tapping
    /// "7 days". `totalTokensIncludingCacheCreation` is the field the dashboard
    /// now reads for every window instead.
    func testTokenMetricIncludingCacheCreationIsConsistentAcrossWindowSelections() {
        func row(_ offset: Int) -> DailyTokenUsage {
            let today = calendar.startOfDay(for: now)
            let date = CalendarDayStep.day(today, offsetBy: -offset, calendar: calendar)
            return DailyTokenUsage(
                date: date,
                provider: .claudeCode,
                inputTokens: 100,
                outputTokens: 50,
                cacheCreationTokens: 40,
                cacheReadTokens: 10,
                estimatedCostUSD: 1.0
            )
        }
        let perDayTokens = 100 + 50 + 40 + 10
        let dailyUsage = (0..<30).map(row)
        let costs = [
            TokenCost(
                provider: .claudeCode,
                inputTokens: 100 * 30,
                outputTokens: 50 * 30,
                cacheCreationTokens: 40 * 30,
                cacheReadTokens: 10 * 30,
                estimatedCostUSD: 30,
                sessionCount: 30,
                periodStart: dailyUsage.last!.date,
                periodEnd: dailyUsage.first!.date
            ),
        ]
        let summary = CostSummary(
            costs: costs,
            totalCostUSD: 30,
            totalTokens: costs[0].totalTokens,
            periodDays: 30,
            dailyUsage: dailyUsage
        )
        XCTAssertEqual(summary.totalTokens, perDayTokens * 30)

        let week = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)
        let monthToDate = summary.monthToDateCostWindow(now: now, calendar: calendar)

        // Sanity check that this fixture actually exercises the gap: the
        // CLI-compatibility figure still omits cache-creation tokens.
        XCTAssertNotEqual(week.totalTokens, week.totalTokensIncludingCacheCreation)

        XCTAssertEqual(week.totalTokensIncludingCacheCreation, perDayTokens * 7)
        XCTAssertEqual(monthToDate.totalTokensIncludingCacheCreation, perDayTokens * monthToDate.requestedDays)

        // The per-day rate every window implies is identical — "tokens" is the
        // same metric whether 7, 30, or Month-to-Date days are selected.
        let unwindowedPerDay = Double(summary.totalTokens) / 30
        XCTAssertEqual(Double(week.totalTokensIncludingCacheCreation) / 7, unwindowedPerDay, accuracy: 0.0001)
        XCTAssertEqual(
            Double(monthToDate.totalTokensIncludingCacheCreation) / Double(monthToDate.requestedDays),
            unwindowedPerDay,
            accuracy: 0.0001
        )
    }

    func testMonthToDateOmitsAttributionWhenAnyIncludedLegacyRowLacksIt() throws {
        let model = breakdown(name: "claude-opus-5", input: 10, cost: 1)
        let summary = summary(
            dailyUsage: [
                row(
                    daysAgo: 0,
                    provider: .claudeCode,
                    input: 10,
                    output: 0,
                    cacheRead: 0,
                    cost: 1,
                    modelBreakdowns: [model],
                    projectBreakdowns: [
                        breakdown(name: "meterbardev", input: 10, cost: 1, models: [model])
                    ]
                ),
                row(
                    daysAgo: 1,
                    provider: .claudeCode,
                    input: 5,
                    output: 0,
                    cacheRead: 0,
                    cost: 0.5
                )
            ],
            periodDays: 30
        )

        let provider = try XCTUnwrap(
            summary.monthToDateCostWindow(now: now, calendar: calendar).providers.first
        )

        XCTAssertNil(provider.modelBreakdowns)
        XCTAssertNil(provider.projectBreakdowns)
    }
}
