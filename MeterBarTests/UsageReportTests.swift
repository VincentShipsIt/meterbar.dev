import MeterBarShared
import XCTest
@testable import MeterBar

/// The Usage page's numbers (issue #593). Every figure the headline strip, the
/// chart, the breakdown table and the insights column show is cut from one
/// `UsageReport`, so these tests pin the contract that the page is consistent:
/// one window, one set of rows, and no ratio built from a saturated total.
final class UsageReportTests: XCTestCase {
    // MARK: - Windowed headline KPIs

    func testHeadlineFollowsTheSelectedWindow() {
        let summary = Self.mixedSummary()

        let week = Self.report(summary, .week)
        let month = Self.report(summary, .month)

        // Week: 7 Claude days (1,150 tokens, $1) + 7 Codex days (1,000, $0.50).
        XCTAssertEqual(week.headline.totalTokens, 7 * 1_150 + 7 * 1_000)
        XCTAssertEqual(week.headline.costUSD, 7 * 1.0 + 7 * 0.5, accuracy: 0.000_001)
        // Month: 21 Claude days + 10 Codex days.
        XCTAssertEqual(month.headline.totalTokens, 21 * 1_150 + 10 * 1_000)
        XCTAssertEqual(month.headline.costUSD, 21 * 1.0 + 10 * 0.5, accuracy: 0.000_001)
    }

    /// The bug behind the issue: only the tokens tile followed the window while
    /// the share, cache and ratio tiles kept reading the full scan.
    func testEveryHeadlineKPIChangesWithTheWindow() throws {
        let summary = Self.recentPremiumSummary()

        let week = Self.report(summary, .week)
        let month = Self.report(summary, .month)

        XCTAssertNotEqual(week.headline.costUSD, month.headline.costUSD)
        XCTAssertNotEqual(week.headline.totalTokens, month.headline.totalTokens)
        XCTAssertNotEqual(week.headline.cacheReadShare, month.headline.cacheReadShare)
        // Last week is all Opus; the older three weeks are all Haiku.
        XCTAssertEqual(try XCTUnwrap(week.headline.premiumShare), 1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(month.headline.premiumShare), 7.0 / 28.0, accuracy: 0.000_001)
    }

    func testCacheReadShareIsCacheReadsOverAllTokens() throws {
        let week = Self.report(Self.mixedSummary(), .week)

        // Claude 800/day + Codex 600/day read from cache, out of 2,150/day.
        XCTAssertEqual(
            try XCTUnwrap(week.headline.cacheReadShare),
            Double(7 * 800 + 7 * 600) / Double(7 * 1_150 + 7 * 1_000),
            accuracy: 0.000_001
        )
    }

    func testPremiumShareCountsTheNewFrontierFamilies() throws {
        let week = Self.report(Self.mixedSummary(), .week)

        // Opus (600/day) and gpt-6-astra (1,000/day) are premium; Sonnet (550) is not.
        XCTAssertEqual(
            try XCTUnwrap(week.headline.premiumShare),
            Double(7 * 600 + 7 * 1_000) / Double(7 * 600 + 7 * 550 + 7 * 1_000),
            accuracy: 0.000_001
        )
    }

    func testCompositionAddsUpToTheHeadlineTotal() {
        let month = Self.report(Self.mixedSummary(), .month)

        XCTAssertEqual(month.composition.total, Double(month.headline.totalTokens), accuracy: 0.5)
        XCTAssertEqual(month.composition.cacheRead, Double(21 * 800 + 10 * 600))
        XCTAssertEqual(month.composition.cacheWrite, Double(21 * 200))
    }

    func testAnEmptyWindowHasNoDataAndNoInsights() {
        let summary = Self.mixedSummary(daysBack: 40, gapDays: 35)
        let report = Self.report(summary, .week)

        XCTAssertFalse(report.hasData)
        XCTAssertEqual(report.headline.totalTokens, 0)
        XCTAssertNil(report.headline.cacheReadShare)
        XCTAssertNil(report.headline.premiumShare)
        XCTAssertTrue(report.insights.recommendations.isEmpty)
    }

    func testMonthToDateWindowStartsOnTheFirst() {
        let report = Self.report(Self.mixedSummary(), .monthToDate)

        // Now is 2026-09-29: the 1st through the 29th is 29 days.
        XCTAssertEqual(report.windowDays, 29)
        XCTAssertEqual(report.windowStart, Self.calendar.startOfDay(for: Self.date("2026-09-01T00:00:00Z")))
    }

    // MARK: - Cache reuse is qualified when a provider reports no cache writes

    func testCacheReuseIgnoresProvidersThatDoNotReportCacheWrites() throws {
        let week = Self.report(Self.mixedSummary(), .week)

        // Claude only: 5,600 reads / (5,600 reads + 1,400 writes). Folding Codex's
        // reads in against zero writes would read 87.5% and drift toward 100%.
        XCTAssertEqual(try XCTUnwrap(week.insights.cacheReuseRatio), 0.8, accuracy: 0.000_001)
    }

    func testCacheReuseIsAbsentWhenNoProviderReportsCacheWrites() {
        let summary = Self.codexOnlySummary()
        let report = Self.report(summary, .month)

        XCTAssertNil(report.insights.cacheReuseRatio, "a 100% tile from zero writes is a lie")
        XCTAssertFalse(report.insights.recommendations.contains { $0.id == "cache-reuse" })
        XCTAssertNotNil(report.headline.cacheReadShare, "reads over all tokens is still measured")
        let note = report.notes.first { $0.id == "cache-writes-unreported" }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.text.contains("Codex") == true)
    }

    func testLegacyRowsWithoutAuthoritativeCacheWritesDoNotCountAsReporting() {
        let legacy = (0..<7).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 50,
                cacheWrite: 0,
                cacheRead: 900,
                cost: 1,
                cacheWriteIsAuthoritative: false
            )
        }
        let summary = Self.summary(daily: legacy)

        let report = Self.report(summary, .week)

        XCTAssertNil(report.insights.cacheReuseRatio)
    }

    func testLowCacheReuseWarnsWhenAProviderReportsWrites() {
        let rows = (0..<7).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 100,
                cacheWrite: 900,
                cacheRead: 100,
                cost: 1
            )
        }
        let report = Self.report(Self.summary(daily: rows), .week)

        let cache = report.insights.recommendations.first { $0.id == "cache-reuse" }
        XCTAssertEqual(cache?.severity, .warning)
        XCTAssertNotNil(cache?.source)
    }

    // MARK: - Tiers for the new model families

    func testFrontierAndGrokFamiliesAreClassified() {
        XCTAssertEqual(ModelTier.classify("gpt-6-astra"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-6"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-5.6-sol"), .premium)
        XCTAssertEqual(ModelTier.classify("gpt-6-mini"), .economy, "economy markers still win")
        XCTAssertEqual(ModelTier.classify("grok-4.6-build"), .standard)
        XCTAssertEqual(ModelTier.classify("grok-4.5"), .standard)
        XCTAssertEqual(ModelTier.classify("grok-4.6-mini"), .economy)
        XCTAssertNotEqual(ModelTier.classify("grok-4.6-build"), .unknown)
        XCTAssertNotEqual(ModelTier.classify("gpt-6-astra"), .unknown)
    }

    // MARK: - Chart stacking modes

    func testProviderStackingSumsToTheDayTotalInBothMetrics() throws {
        let report = Self.report(Self.mixedSummary(), .month)

        for metric in UsageMetric.allCases {
            let series = report.series(UsageChartSelection(metric: metric, stacking: .provider))
            XCTAssertEqual(
                Set(series.categories.map(\.name)),
                [ServiceType.claudeCode.displayName, ServiceType.codexCli.displayName]
            )
            try Self.assertStacksMatchDayTotals(series, in: report)
        }
    }

    func testProviderStackingIncludesEveryTrackedServiceInBothMetrics() throws {
        let rows = ServiceType.allCases.map {
            Self.dailyRow(
                daysAgo: 0,
                provider: $0,
                input: 1000,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1
            )
        }
        let report = Self.report(Self.summary(daily: rows), .week)
        let today = Self.calendar.startOfDay(for: Self.now)
        let providers = ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(report.headline.totalTokens, providers.count * 1000)

        for metric in UsageMetric.allCases {
            let series = report.series(UsageChartSelection(metric: metric, stacking: .provider))
            XCTAssertEqual(series.categories.compactMap(\.provider), providers)
            let points = series.points.filter { $0.date == today }
            XCTAssertEqual(Set(points.map(\.category)), Set(providers.map(\.displayName)))
            XCTAssertEqual(points.count, providers.count)
            XCTAssertTrue(points.allSatisfy { $0.value == (metric == .tokens ? 1000 : 1) })
            try Self.assertStacksMatchDayTotals(series, in: report)
        }
    }

    func testTokenTypeStackingHasTheFourKindsInOrder() throws {
        let report = Self.report(Self.mixedSummary(), .week)
        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .tokenType))

        XCTAssertEqual(series.categories.map(\.name), ["Input", "Output", "Cache write", "Cache read"])
        XCTAssertEqual(series.categories.compactMap(\.kind), TokenKind.allCases)
        try Self.assertStacksMatchDayTotals(series, in: report)

        // One day with both providers: input 100 + 300, output 50 + 100,
        // cache write 200 + 0, cache read 800 + 600.
        let today = Self.calendar.startOfDay(for: Self.now)
        let todayPoints = series.points.filter { $0.date == today }
        func value(_ name: String) -> Double? { todayPoints.first { $0.category == name }?.value }
        XCTAssertEqual(value("Input"), 400)
        XCTAssertEqual(value("Output"), 150)
        XCTAssertEqual(value("Cache write"), 200)
        XCTAssertEqual(value("Cache read"), 1_400)
    }

    func testModelStackingUsesTheDailyModelAttribution() throws {
        let report = Self.report(Self.mixedSummary(), .week)
        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .model))

        XCTAssertEqual(
            Set(series.categories.map(\.name)),
            ["claude-opus-4-8", "claude-sonnet-4-5", "gpt-6-astra"]
        )
        try Self.assertStacksMatchDayTotals(series, in: report)
    }

    func testModelStackingKeepsTheTopFiveAndFoldsTheRestIntoOther() throws {
        let models = (1...8).map { index in
            Self.breakdown(.claudeCode, "model-\(index)", input: index * 100)
        }
        let rows = (0..<7).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 3_600,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1,
                models: models
            )
        }
        let report = Self.report(Self.summary(daily: rows), .week)

        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .model))

        XCTAssertEqual(series.categories.count, 6)
        XCTAssertEqual(series.categories.last?.name, "Other")
        XCTAssertEqual(
            series.categories.dropLast().map(\.name),
            ["model-8", "model-7", "model-6", "model-5", "model-4"]
        )
        try Self.assertStacksMatchDayTotals(series, in: report)
    }

    func testRowsWithoutModelAttributionStackAsUnattributed() throws {
        let rows = (0..<7).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1,
                models: nil
            )
        }
        let report = Self.report(Self.summary(daily: rows), .week)

        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .model))

        XCTAssertEqual(series.categories.map(\.name), ["Unattributed"])
        try Self.assertStacksMatchDayTotals(series, in: report)
    }

    /// Cost is one number per row, not per token type, so a cost chart cannot be
    /// split four ways without inventing prices. The combination is unavailable
    /// and a stale selection is coerced rather than drawn wrong.
    func testTokenTypeStackingIsOnlyAvailableForTokens() {
        XCTAssertEqual(UsageStacking.available(for: .tokens), [.provider, .tokenType, .model])
        XCTAssertEqual(UsageStacking.available(for: .cost), [.provider, .model])

        let coerced = UsageChartSelection(metric: .cost, stacking: .tokenType).normalized()
        XCTAssertEqual(coerced, UsageChartSelection(metric: .cost, stacking: .provider))
        let kept = UsageChartSelection(metric: .tokens, stacking: .tokenType).normalized()
        XCTAssertEqual(kept, UsageChartSelection(metric: .tokens, stacking: .tokenType))
    }

    func testSeriesDaysCoverTheWholeWindowOldestFirst() {
        let report = Self.report(Self.mixedSummary(), .week)
        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .provider))

        XCTAssertEqual(series.days.count, 7)
        XCTAssertEqual(series.days.first, report.windowStart)
        XCTAssertEqual(series.days.last, Self.calendar.startOfDay(for: Self.now))
    }

    func testEveryProviderCanDraw() {
        let rows = ServiceType.allCases.map { provider in
            Self.dailyRow(
                daysAgo: 0,
                provider: provider,
                input: 1_000,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1
            )
        }
        let report = Self.report(Self.summary(daily: rows), .week)

        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .provider))

        XCTAssertEqual(Set(series.categories.compactMap(\.provider)), Set(ServiceType.allCases))
        XCTAssertEqual(
            series.categories.compactMap(\.provider),
            ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }
        )
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06, so
    /// the local day starts at 01:00. Stepping back from that instant without
    /// re-normalizing every hop misses every earlier row.
    func testWindowSurvivesTheSantiagoMidnightTransition() throws {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let dstNow = Self.date("2026-09-06T13:00:00Z")
        let today = santiago.startOfDay(for: dstNow)
        let sixDaysAgo = CalendarDayStep.day(today, offsetBy: -6, calendar: santiago)
        let rows = [
            DailyTokenUsage(
                date: today.addingTimeInterval(3_600 * 3),
                provider: .claudeCode,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 1
            ),
            DailyTokenUsage(
                date: sixDaysAgo.addingTimeInterval(3_600 * 5),
                provider: .claudeCode,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 1
            ),
        ]

        let report = UsageReport(
            summary: Self.summary(daily: rows),
            selection: .week,
            now: dstNow,
            calendar: santiago
        )

        XCTAssertEqual(report.headline.totalTokens, 200)
        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .provider))
        XCTAssertEqual(series.days.count, 7)
        XCTAssertEqual(series.days.first, sixDaysAgo)
        XCTAssertEqual(series.days.last, today)
    }

    /// OpenRouter buckets its rows in UTC; a Pacific viewer must still see
    /// September 29th as the 29th rather than the evening of the 28th.
    func testUTCKeyedRowsLandOnTheirOwnCalendarDay() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = Self.date("2026-09-29T20:00:00Z")
        let row = DailyTokenUsage(
            date: Self.date("2026-09-29T00:00:00Z"),
            provider: .openRouter,
            inputTokens: 500,
            outputTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 2
        )

        let report = UsageReport(summary: Self.summary(daily: [row]), selection: .week, now: now, calendar: pacific)

        let series = report.series(UsageChartSelection(metric: .cost, stacking: .provider))
        XCTAssertEqual(series.points.map(\.date), [pacific.startOfDay(for: now)])
        XCTAssertEqual(series.points.first?.value, 2)
    }

    // MARK: - Saturated totals

    /// Two providers each carrying `Int.max` in one day must stay inside one
    /// column and keep their real proportion (issue #591's failure mode, on the
    /// new chart).
    func testTwoSaturatedProvidersStayInOneColumnAtTheirRealProportion() throws {
        let rows = [
            Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: Int.max, output: 0, cacheWrite: 0, cacheRead: 0, cost: 1),
            Self.dailyRow(daysAgo: 0, provider: .codexCli, input: Int.max, output: 0, cacheWrite: 0, cacheRead: 0, cost: 1),
        ]
        let report = Self.report(Self.summary(daily: rows), .week)

        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .provider))
        let total = try XCTUnwrap(series.maxDayTotal)

        XCTAssertEqual(total, 2 * Double(Int.max))
        XCTAssertEqual(series.points.map(\.value).reduce(0, +), total)
        for point in series.points {
            XCTAssertEqual(point.value / total, 0.5, accuracy: 1e-12)
        }
    }

    /// Two days that both read `Int.max` as a displayed total still differ by
    /// their real size, so the taller column stays taller.
    func testColumnsKeepTheirRelativeSizeForDaysThatBothSaturateTheirTotals() throws {
        let rows = [
            Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: Int.max, output: Int.max, cacheWrite: 0, cacheRead: 0, cost: 1),
            Self.dailyRow(daysAgo: 1, provider: .claudeCode, input: Int.max, output: 0, cacheWrite: 0, cacheRead: 0, cost: 1),
        ]
        let report = Self.report(Self.summary(daily: rows), .week)

        let series = report.series(UsageChartSelection(metric: .tokens, stacking: .provider))
        let today = Self.calendar.startOfDay(for: Self.now)
        let yesterday = CalendarDayStep.day(today, offsetBy: -1, calendar: Self.calendar)

        XCTAssertEqual(series.points.first { $0.date == today }?.value, 2 * Double(Int.max))
        XCTAssertEqual(series.points.first { $0.date == yesterday }?.value, Double(Int.max))
        XCTAssertEqual(try XCTUnwrap(series.maxDayTotal), 2 * Double(Int.max))
    }

    func testEquallyOverflowingModelsShareEvenly() throws {
        let rows = [
            Self.dailyRow(
                daysAgo: 0,
                provider: .claudeCode,
                input: Int.max,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 2,
                models: [
                    Self.breakdown(.claudeCode, "claude-opus-5", input: Int.max),
                    Self.breakdown(.claudeCode, "claude-haiku-4-5", input: Int.max),
                ]
            ),
        ]
        let report = Self.report(Self.summary(daily: rows), .week)

        XCTAssertEqual(try XCTUnwrap(report.headline.premiumShare), 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.breakdown(.model).map(\.share), [0.5, 0.5])
    }

    func testUnequalOverflowingModelsKeepTheirRatiosAndOrdering() throws {
        // Opus overflows twice over (input + cache read); Haiku once.
        let opus = Self.breakdown(.claudeCode, "claude-opus-5", input: Int.max, cacheRead: Int.max)
        let haiku = Self.breakdown(.claudeCode, "claude-haiku-4-5", input: Int.max)
        let rows = [
            Self.dailyRow(
                daysAgo: 0,
                provider: .claudeCode,
                input: Int.max,
                output: 0,
                cacheWrite: 0,
                cacheRead: Int.max,
                cost: 2,
                models: [opus, haiku]
            ),
        ]
        let report = Self.report(Self.summary(daily: rows), .week)

        let models = report.breakdown(.model)

        XCTAssertEqual(models.map(\.name), ["claude-opus-5", "claude-haiku-4-5"])
        XCTAssertEqual(models[0].share, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(models[1].share, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(report.headline.premiumShare), 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - Breakdown table

    func testModelBreakdownIsWindowedAndCarriesTheFourPartComposition() throws {
        let report = Self.report(Self.mixedSummary(), .week)

        let rows = report.breakdown(.model)

        XCTAssertEqual(rows.map(\.name), ["gpt-6-astra", "claude-opus-4-8", "claude-sonnet-4-5"])
        let opus = try XCTUnwrap(rows.first { $0.name == "claude-opus-4-8" })
        XCTAssertEqual(opus.composition, TokenComposition(input: 7 * 60, output: 7 * 30, cacheWrite: 7 * 100, cacheRead: 7 * 410))
        XCTAssertEqual(opus.provider, .claudeCode)
        XCTAssertEqual(opus.costUSD, 7 * 0.6, accuracy: 0.000_001)
        XCTAssertEqual(opus.tier, .premium)
        XCTAssertEqual(rows.map(\.share).reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertNil(report.notes.first { $0.id == "model-detail-scan-period" })
    }

    func testModelBreakdownFallsBackToTheScanWhenRowsPredateAttribution() throws {
        let rows = (0..<7).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1,
                models: nil,
                projects: nil
            )
        }
        var summary = Self.summary(daily: rows)
        summary = Self.withCost(
            summary,
            provider: .claudeCode,
            models: [Self.breakdown(.claudeCode, "claude-opus-4-8", input: 9_000)],
            projects: [Self.breakdown(.claudeCode, "meterbar", input: 9_000)]
        )

        let report = Self.report(summary, .week)

        XCTAssertEqual(report.breakdown(.model).map(\.name), ["claude-opus-4-8"])
        XCTAssertEqual(report.breakdown(.project).map(\.name), ["meterbar"])
        XCTAssertNotNil(report.notes.first { $0.id == "model-detail-scan-period" })
        XCTAssertNotNil(report.notes.first { $0.id == "project-detail-scan-period" })
    }

    func testPartiallyAttributedRowsSurfaceAnUnattributedRemainder() throws {
        let rows = [
            Self.dailyRow(
                daysAgo: 0,
                provider: .claudeCode,
                input: 1_000,
                output: 0,
                cacheWrite: 0,
                cacheRead: 0,
                cost: 1,
                models: [Self.breakdown(.claudeCode, "claude-opus-4-8", input: 600)]
            ),
        ]
        let report = Self.report(Self.summary(daily: rows), .week)

        let models = report.breakdown(.model)

        XCTAssertEqual(models.map(\.name), ["claude-opus-4-8", "Unattributed"])
        XCTAssertEqual(models.last?.composition.total, 400)
        XCTAssertEqual(models.map(\.share).reduce(0, +), 1, accuracy: 0.000_001)
        // Unattributed tokens are not evidence about the mix.
        XCTAssertEqual(try XCTUnwrap(report.headline.premiumShare), 1, accuracy: 0.000_001)
    }

    func testProviderBreakdownComesFromTheWindowRows() {
        let report = Self.report(Self.mixedSummary(), .week)

        let rows = report.breakdown(.provider)

        XCTAssertEqual(Set(rows.map(\.name)), [ServiceType.claudeCode.displayName, ServiceType.codexCli.displayName])
        XCTAssertEqual(rows.first { $0.provider == .claudeCode }?.composition.total, 7 * 1_150)
        XCTAssertEqual(rows.first { $0.provider == .codexCli }?.costUSD ?? 0, 7 * 0.5, accuracy: 0.000_001)
    }

    func testProjectBreakdownIsWindowed() {
        let report = Self.report(Self.mixedSummary(), .week)

        let rows = report.breakdown(.project)

        // Codex's rows carry no project, so its week is the honest remainder.
        XCTAssertEqual(rows.map(\.name), ["meterbar", "Unattributed"])
        XCTAssertEqual(rows.first?.composition.total, 7 * 1_150)
        XCTAssertEqual(rows.last?.composition.total, 7 * 1_000)
        XCTAssertEqual(rows.last?.provider, .codexCli)
    }

    /// Origins are a scan-period rollup; the daily rows carry no origin split. A
    /// week cannot be cut from them, so the table says so instead of scaling.
    func testOriginBreakdownIsScanPeriodAndFlaggedWhenTheWindowIsNarrower() {
        let summary = Self.mixedSummary()

        let week = Self.report(summary, .week)
        let month = Self.report(summary, .month)

        XCTAssertEqual(week.breakdown(.origin).map(\.name), ["Agents", "Main chat"])
        XCTAssertFalse(week.originsCoverWindow)
        XCTAssertNotNil(week.notes.first { $0.id == "origin-scan-period" })
        XCTAssertTrue(month.originsCoverWindow, "the actual origin dates fit, regardless of requested scan width")
        XCTAssertNil(month.notes.first { $0.id == "origin-scan-period" })
    }

    func testBreakdownRowsAreSortedByTokensAndSharesAreFractions() {
        let report = Self.report(Self.mixedSummary(), .month)

        for tab in UsageBreakdownTab.allCases {
            let rows = report.breakdown(tab)
            XCTAssertEqual(rows.map(\.composition.total), rows.map(\.composition.total).sorted(by: >), "\(tab)")
            for row in rows {
                XCTAssertGreaterThanOrEqual(row.share, 0)
                XCTAssertLessThanOrEqual(row.share, 1)
            }
        }
    }

    func testCompositionFractionsSplitIntoFourSegments() {
        let composition = TokenComposition(input: 10, output: 20, cacheWrite: 30, cacheRead: 40)

        XCTAssertEqual(composition.total, 100)
        XCTAssertEqual(composition.fraction(.input), 0.1, accuracy: 1e-12)
        XCTAssertEqual(composition.fraction(.cacheRead), 0.4, accuracy: 1e-12)
        XCTAssertEqual(TokenKind.allCases.map(composition.fraction).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(TokenComposition.zero.fraction(.input), 0, "an empty row draws an empty bar")
    }

    // MARK: - Insights are windowed and carry their source number

    func testInsightsChangeWithTheWindow() throws {
        let summary = Self.recentPremiumSummary()

        let week = Self.report(summary, .week)
        let month = Self.report(summary, .month)

        let weekPremium = try XCTUnwrap(week.insights.recommendations.first { $0.id == "premium-share" })
        XCTAssertEqual(weekPremium.severity, .warning)
        XCTAssertNil(
            month.insights.recommendations.first { $0.id == "premium-share" },
            "7 of 28 days is 25% premium: below every threshold"
        )
    }

    func testEveryInsightExceptTheLeanFallbackNamesItsSourceNumber() {
        let report = Self.report(Self.recentPremiumSummary(), .month)

        for recommendation in report.insights.recommendations where recommendation.id != "lean" {
            XCTAssertFalse(recommendation.source?.isEmpty ?? true, "\(recommendation.id) shows no number")
        }
    }

    func testPremiumInsightQuotesItsShare() throws {
        let report = Self.report(Self.recentPremiumSummary(), .week)

        let premium = try XCTUnwrap(report.insights.recommendations.first { $0.id == "premium-share" })

        XCTAssertTrue(premium.source?.contains("100%") == true, premium.source ?? "nil")
        XCTAssertTrue(premium.detail.contains("$$$"))
    }

    func testTrendInsightNeedsAWindowLongerThanAWeekAndFullCoverage() throws {
        let summary = Self.hotWeekSummary()

        XCTAssertNil(Self.report(summary, .week).insights.recommendations.first { $0.id == "trend-up" })
        let trend = try XCTUnwrap(Self.report(summary, .month).insights.recommendations.first { $0.id == "trend-up" })
        XCTAssertNotNil(trend.source)

        // Five days of history is not a 30-day average.
        let sparse = Self.summary(daily: (0..<5).map { offset in
            Self.dailyRow(daysAgo: offset, provider: .claudeCode, input: 1_000, output: 100, cacheWrite: 0, cacheRead: 0, cost: 1)
        })
        XCTAssertNil(Self.report(sparse, .month).insights.recommendations.first { $0.id == "trend-up" })
    }

    func testOriginConcentrationOnlyAppearsWhenOriginsCoverTheWindow() {
        let summary = Self.mixedSummary(topOriginShare: 0.7)

        XCTAssertNotNil(Self.report(summary, .month).insights.recommendations.first { $0.id == "origin-concentration" })
        XCTAssertNil(Self.report(summary, .week).insights.recommendations.first { $0.id == "origin-concentration" })
    }

    func testRecommendationsAreSortedBySeverityDescending() {
        let report = Self.report(Self.recentPremiumSummary(), .month)
        let severities = report.insights.recommendations.map(\.severity.rawValue)

        XCTAssertEqual(severities, severities.sorted(by: >))
    }

    func testLeanUsageRaisesNoWarnings() {
        let rows = (0..<30).map { offset in
            Self.dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 100,
                cacheWrite: 100,
                cacheRead: 900,
                cost: 1,
                models: [Self.breakdown(.claudeCode, "claude-haiku-4-5", input: 100, output: 100, cacheWrite: 100, cacheRead: 900)]
            )
        }
        let report = Self.report(Self.summary(daily: rows), .month)

        XCTAssertFalse(report.insights.recommendations.isEmpty)
        XCTAssertFalse(report.insights.recommendations.contains { $0.severity == .warning })
    }

    // MARK: - Data-quality notes

    func testPricingProvenanceIsAlwaysNoted() {
        let report = Self.report(Self.mixedSummary(), .week)

        let note = report.notes.first { $0.id == "pricing" }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.text.contains("Rates verified") == true)
    }

    func testPricingNoteWarnsWhenEventsPredateTheTable() {
        var provenance = PricingProvenance(verificationDates: ["2026-07-02"])
        provenance.record(
            ResolvedPricing(
                pricing: TokenPricing(input: 1, output: 1, cacheCreation: 1, cacheRead: 1),
                effectiveFrom: Date(timeIntervalSince1970: 0),
                verifiedOn: "2026-07-02",
                precedesFirstEntry: true
            )
        )
        let summary = Self.summary(daily: [Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: 10, output: 1, cacheWrite: 0, cacheRead: 0, cost: 1)], pricing: provenance)

        let report = Self.report(summary, .week)

        XCTAssertEqual(report.notes.first { $0.id == "pricing" }?.severity, .warning)
    }

    func testGrokCostIsNotedAsReportedNotEstimated() {
        let rows = [Self.dailyRow(daysAgo: 0, provider: .grok, input: 10, output: 1, cacheWrite: 0, cacheRead: 5, cost: 1)]
        let report = Self.report(Self.summary(daily: rows), .week)

        XCTAssertNotNil(report.notes.first { $0.id == "grok-reported-cost" })
        XCTAssertNil(Self.report(Self.mixedSummary(), .week).notes.first { $0.id == "grok-reported-cost" })
    }

    func testCoverageGapIsNotedWhenHistoryIsShorterThanTheWindow() {
        let sparse = Self.summary(daily: (0..<5).map { offset in
            Self.dailyRow(daysAgo: offset, provider: .claudeCode, input: 1_000, output: 100, cacheWrite: 0, cacheRead: 0, cost: 1)
        })

        let month = Self.report(sparse, .month)
        let week = Self.report(sparse, .week)

        XCTAssertEqual(month.coveredDays, 5)
        XCTAssertNotNil(month.notes.first { $0.id == "coverage" })
        XCTAssertNil(Self.report(Self.mixedSummary(), .week).notes.first { $0.id == "coverage" })
        XCTAssertNotNil(week.notes.first { $0.id == "coverage" })
    }

    func testCompressedRolloutsAreWarnedAbout() {
        let report = UsageReport(
            summary: Self.mixedSummary(),
            selection: .week,
            compressedCodexRollouts: 3,
            now: Self.now,
            calendar: Self.calendar
        )

        let note = report.notes.first { $0.id == "compressed-rollouts" }
        XCTAssertEqual(note?.severity, .warning)
        XCTAssertTrue(note?.text.contains("3") == true)
        XCTAssertNil(Self.report(Self.mixedSummary(), .week).notes.first { $0.id == "compressed-rollouts" })
    }

    func testLegacyModelAttributionDoesNotFeedTheWindowPremiumSignal() {
        let daily = [
            Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: 100, output: 0,
                          cacheWrite: 0, cacheRead: 0, cost: 1,
                          models: [Self.breakdown(.claudeCode, "claude-haiku-4-5", input: 100)]),
            Self.dailyRow(daysAgo: 1, provider: .claudeCode, input: 100, output: 0,
                          cacheWrite: 0, cacheRead: 0, cost: 1, models: nil, projects: nil),
        ]
        let summary = Self.withCost(Self.summary(daily: daily), provider: .claudeCode,
                                    models: [Self.breakdown(.claudeCode, "claude-opus-5", input: 9_000)],
                                    projects: [Self.breakdown(.claudeCode, "project", input: 9_000)])
        let report = Self.report(summary, .week)

        XCTAssertEqual(report.headline.totalTokens, 200)
        XCTAssertNil(report.headline.premiumShare)
        XCTAssertNil(report.insights.premiumTokenShare)
        XCTAssertNil(report.insights.recommendations.first { $0.id == "premium-share" })
        XCTAssertEqual(report.breakdown(.model).first?.tokens, 9_000)
        XCTAssertEqual(UsageBreakdownCard.scopeCaption(for: .model, in: report), "31-day scan")
        XCTAssertEqual(UsageBreakdownCard.scopeCaption(for: .project, in: report), "31-day scan")
        XCTAssertEqual(UsageBreakdownCard.scopeCaption(for: .provider, in: report), "Last 7 days")
    }

    func testSaturatedModelDetailRecoversOneCommonTotalForAllStacks() throws {
        let opus = Self.breakdown(.claudeCode, "claude-opus-5", input: Int.max, cacheRead: Int.max)
        let haiku = Self.breakdown(.claudeCode, "claude-haiku-4-5", input: Int.max)
        let daily = Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: Int.max, output: 100,
                                 cacheWrite: 0, cacheRead: Int.max, cost: 2, models: [opus, haiku])
        let report = Self.report(Self.summary(daily: [daily]), .week)

        XCTAssertEqual(report.composition.input, 2 * Double(Int.max))
        XCTAssertEqual(report.composition.cacheRead, Double(Int.max))
        XCTAssertEqual(report.breakdown(.model).first?.share ?? 0, 2.0 / 3.0, accuracy: 1e-12)
        for stacking in UsageStacking.allCases {
            try Self.assertStacksMatchDayTotals(report.series(.init(metric: .tokens, stacking: stacking)), in: report)
        }
    }

    func testUnsaturatedAttributionCannotExceedAuthoritativeComponentsOrCost() throws {
        let daily = Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: 100, output: 0,
                                 cacheWrite: 0, cacheRead: 0, cost: 1, models: [
                                    Self.breakdown(.claudeCode, "claude-opus-5", input: 100),
                                    Self.breakdown(.claudeCode, "claude-haiku-4-5", input: 100),
                                 ])
        let report = Self.report(Self.summary(daily: [daily]), .week)
        XCTAssertEqual(report.composition.total, 100)
        XCTAssertEqual(report.breakdown(.model).map(\.tokens), [50, 50])
        for metric in UsageMetric.allCases {
            for stacking in UsageStacking.available(for: metric) {
                try Self.assertStacksMatchDayTotals(report.series(.init(metric: metric, stacking: stacking)), in: report)
            }
        }
    }

    func testOriginInsightRequiresActualScanDatesInsideTheWindow() {
        let today = Self.calendar.startOfDay(for: Self.now)
        func report(scanDaysAgo: Int, periodDays: Int) -> UsageReport {
            let cost = TokenCost(provider: .claudeCode, inputTokens: 10_000, outputTokens: 0,
                                 cacheCreationTokens: 0, cacheReadTokens: 0, estimatedCostUSD: 1,
                                 sessionCount: 1,
                                 periodStart: CalendarDayStep.day(today, offsetBy: -scanDaysAgo, calendar: Self.calendar),
                                 periodEnd: Self.now,
                                 originBreakdowns: [Self.breakdown(.claudeCode, "Agents", input: 9_900),
                                                    Self.breakdown(.claudeCode, "Main chat", input: 100)])
            let daily = Self.dailyRow(daysAgo: 0, provider: .claudeCode, input: 100, output: 0,
                                     cacheWrite: 0, cacheRead: 0, cost: 1)
            return Self.report(Self.summary(daily: [daily], costs: [cost], periodDays: periodDays), .month)
        }
        let outside = report(scanDaysAgo: 30, periodDays: 31)
        XCTAssertFalse(outside.originsCoverWindow)
        XCTAssertNil(outside.insights.recommendations.first { $0.id == "origin-concentration" })
        XCTAssertEqual(UsageBreakdownCard.scopeCaption(for: .origin, in: outside), "31-day scan")
        XCTAssertNotNil(outside.notes.first { $0.id == "origin-scan-period" })
        XCTAssertTrue(report(scanDaysAgo: 29, periodDays: 31).originsCoverWindow)
        XCTAssertFalse(report(scanDaysAgo: 30, periodDays: 7).originsCoverWindow,
                       "a short rounded scan width does not prove its date bounds")
    }

    func testSaturatedTrendUsesRawComponentsWithFullHistoryCoverage() throws {
        let rows = (0..<30).map { offset in
            Self.dailyRow(daysAgo: offset, provider: .claudeCode,
                          input: offset < 7 ? Int.max : Int.max / 4, output: 0,
                          cacheWrite: 0, cacheRead: 0, cost: 1)
        }
        let report = Self.report(Self.summary(daily: rows), .month)
        let trend = try XCTUnwrap(report.insights.inputs.trend)
        XCTAssertEqual(trend.recentDailyTokens, Double(Int.max), accuracy: 1_000)
        XCTAssertEqual(trend.windowDailyTokens / Double(Int.max), 0.425, accuracy: 1e-12)
        let recommendation = try XCTUnwrap(report.insights.recommendations.first { $0.id == "trend-up" })
        XCTAssertTrue(recommendation.detail.contains("whole-window average"))
    }

    // MARK: - Fixtures

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static let now = date("2026-09-29T12:00:00Z")

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    static func report(_ summary: CostSummary, _ selection: CostWindowSelection) -> UsageReport {
        UsageReport(summary: summary, selection: selection, now: now, calendar: calendar)
    }

    /// Every stacked column must sum to that day's total, whatever the stacking.
    private static func assertStacksMatchDayTotals(
        _ series: UsageSeries,
        in report: UsageReport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let byDay = Dictionary(grouping: series.points, by: \.date)
        XCTAssertFalse(byDay.isEmpty, file: file, line: line)
        for (day, points) in byDay {
            let stacked = points.map(\.value).reduce(0, +)
            let expected = report.dayTotal(on: day, metric: series.metric)
            XCTAssertEqual(stacked, expected, accuracy: max(1e-6, expected * 1e-12), "\(day)", file: file, line: line)
        }
        XCTAssertEqual(
            series.maxDayTotal,
            byDay.values.map { $0.map(\.value).reduce(0, +) }.max(),
            file: file,
            line: line
        )
    }

    static func breakdown(
        _ provider: ServiceType,
        _ name: String,
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0
    ) -> TokenUsageBreakdown {
        return TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: 1,
            sessionCount: 1
        )
    }

    static func dailyRow(
        daysAgo: Int,
        provider: ServiceType,
        input: Int,
        output: Int,
        cacheWrite: Int,
        cacheRead: Int,
        cost: Double,
        cacheWriteIsAuthoritative: Bool = true,
        models: [TokenUsageBreakdown]? = [],
        projects: [TokenUsageBreakdown]? = []
    ) -> DailyTokenUsage {
        let day = CalendarDayStep.day(calendar.startOfDay(for: now), offsetBy: -daysAgo, calendar: calendar)
        return DailyTokenUsage(
            date: day.addingTimeInterval(3_600 * 5),
            provider: provider,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheWrite,
            cacheCreationTokensAreAuthoritative: cacheWriteIsAuthoritative,
            cacheReadTokens: cacheRead,
            estimatedCostUSD: cost,
            modelBreakdowns: models,
            projectBreakdowns: projects,
            sessionBreakdowns: []
        )
    }

    static func summary(
        daily: [DailyTokenUsage],
        costs: [TokenCost] = [],
        periodDays: Int = 31,
        pricing: PricingProvenance? = nil
    ) -> CostSummary {
        CostSummary(
            costs: costs,
            totalCostUSD: costs.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: periodDays,
            dailyUsage: daily,
            pricing: pricing
        )
    }

    /// Replaces (or adds) one provider's scan-period rollup on a summary.
    static func withCost(
        _ summary: CostSummary,
        provider: ServiceType,
        models: [TokenUsageBreakdown],
        projects: [TokenUsageBreakdown]
    ) -> CostSummary {
        let cost = TokenCost(
            provider: provider,
            inputTokens: 9_000,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1,
            sessionCount: 1,
            periodStart: calendar.startOfDay(for: now),
            periodEnd: now,
            modelBreakdowns: models,
            originBreakdowns: [],
            projectBreakdowns: projects
        )
        return CostSummary(
            costs: summary.costs.filter { $0.provider != provider } + [cost],
            totalCostUSD: summary.totalCostUSD,
            totalTokens: summary.totalTokens,
            periodDays: summary.periodDays,
            dailyUsage: summary.dailyUsage,
            pricing: summary.pricing
        )
    }

    /// Claude for 21 days (input 100, output 50, cache write 200, cache read 800;
    /// $1/day; Opus + Sonnet) and Codex for 10 days (input 300, output 100, no
    /// cache writes, cache read 600; $0.50/day; gpt-6-astra). Today is day 0.
    static func mixedSummary(
        daysBack: Int = 21,
        gapDays: Int = 0,
        topOriginShare: Double = 0.6
    ) -> CostSummary {
        let opus = breakdown(.claudeCode, "claude-opus-4-8", input: 60, output: 30, cacheWrite: 100, cacheRead: 410)
        let sonnet = breakdown(.claudeCode, "claude-sonnet-4-5", input: 40, output: 20, cacheWrite: 100, cacheRead: 390)
        let astra = breakdown(.codexCli, "gpt-6-astra", input: 300, output: 100, cacheWrite: 0, cacheRead: 600)
        let project = breakdown(.claudeCode, "meterbar", input: 100, output: 50, cacheWrite: 200, cacheRead: 800)

        var daily: [DailyTokenUsage] = []
        for offset in gapDays..<max(gapDays, daysBack) {
            daily.append(dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 100,
                output: 50,
                cacheWrite: 200,
                cacheRead: 800,
                cost: 1,
                models: [
                    modelSlice(opus, cost: 0.6),
                    modelSlice(sonnet, cost: 0.4),
                ],
                projects: [project]
            ))
        }
        for offset in gapDays..<max(gapDays, 10) {
            daily.append(dailyRow(
                daysAgo: offset,
                provider: .codexCli,
                input: 300,
                output: 100,
                cacheWrite: 0,
                cacheRead: 600,
                cost: 0.5,
                models: [modelSlice(astra, cost: 0.5)],
                projects: []
            ))
        }

        let heavy = Int(1_000 * topOriginShare / max(0.01, 1 - topOriginShare))
        let claudeScan = TokenCost(
            provider: .claudeCode,
            inputTokens: 21 * 100,
            outputTokens: 21 * 50,
            cacheCreationTokens: 21 * 200,
            cacheReadTokens: 21 * 800,
            estimatedCostUSD: 21,
            sessionCount: 4,
            periodStart: daily.map(\.date).min() ?? now,
            periodEnd: now,
            modelBreakdowns: [opus, sonnet],
            originBreakdowns: [
                breakdown(.claudeCode, "Agents", input: heavy),
                breakdown(.claudeCode, "Main chat", input: 1_000),
            ],
            projectBreakdowns: [project]
        )
        return summary(daily: daily, costs: [claudeScan])
    }

    /// One day's slice of a model: same components, its own price.
    private static func modelSlice(_ base: TokenUsageBreakdown, cost: Double) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: base.provider,
            name: base.name,
            inputTokens: base.inputTokens,
            outputTokens: base.outputTokens,
            cacheCreationTokens: base.cacheCreationTokens,
            cacheReadTokens: base.cacheReadTokens,
            estimatedCostUSD: cost,
            sessionCount: 1
        )
    }

    /// Codex only: no provider in the window reports cache writes.
    static func codexOnlySummary() -> CostSummary {
        let astra = breakdown(.codexCli, "gpt-6-astra", input: 300, output: 100, cacheWrite: 0, cacheRead: 600)
        let daily = (0..<14).map { offset in
            dailyRow(
                daysAgo: offset,
                provider: .codexCli,
                input: 300,
                output: 100,
                cacheWrite: 0,
                cacheRead: 600,
                cost: 0.5,
                models: [modelSlice(astra, cost: 0.5)]
            )
        }
        return summary(daily: daily)
    }

    /// The last seven days are all Opus at 4,000 tokens a day; the 21 days
    /// before that are all Haiku at 4,000 too, priced differently. Last week is
    /// 100% premium; the 28-day month is 25% premium and no hotter per day.
    static func recentPremiumSummary() -> CostSummary {
        let opus = breakdown(.claudeCode, "claude-opus-4-8", input: 1_000, output: 500, cacheWrite: 500, cacheRead: 2_000)
        let haiku = breakdown(.claudeCode, "claude-haiku-4-5", input: 1_500, output: 300, cacheWrite: 300, cacheRead: 1_900)
        let daily = (0..<28).map { offset -> DailyTokenUsage in
            if offset < 7 {
                return dailyRow(
                    daysAgo: offset,
                    provider: .claudeCode,
                    input: 1_000,
                    output: 500,
                    cacheWrite: 500,
                    cacheRead: 2_000,
                    cost: 4,
                    models: [modelSlice(opus, cost: 4)]
                )
            }
            return dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 1_500,
                output: 300,
                cacheWrite: 300,
                cacheRead: 1_900,
                cost: 0.5,
                models: [modelSlice(haiku, cost: 0.5)]
            )
        }
        return summary(daily: daily)
    }

    /// Thirty days of Haiku: 1,000 tokens a day, then 4,000 a day for the last
    /// week. The last seven days run well ahead of the month's average.
    static func hotWeekSummary() -> CostSummary {
        let haiku = breakdown(.claudeCode, "claude-haiku-4-5", input: 500, output: 100, cacheWrite: 100, cacheRead: 300)
        let daily = (0..<30).map { offset -> DailyTokenUsage in
            let scale = offset < 7 ? 4 : 1
            return dailyRow(
                daysAgo: offset,
                provider: .claudeCode,
                input: 500 * scale,
                output: 100 * scale,
                cacheWrite: 100 * scale,
                cacheRead: 300 * scale,
                cost: 0.5,
                models: [modelSlice(haiku, cost: 0.5)]
            )
        }
        return summary(daily: daily)
    }
}
