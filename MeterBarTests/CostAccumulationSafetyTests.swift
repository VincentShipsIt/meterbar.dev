import XCTest
@testable import MeterBar
import MeterBarShared

/// Issue #541: `CostScanValues.int(_:)` deliberately saturates an out-of-range
/// JSON number to `Int.max`/`Int.min` instead of trapping, but every downstream
/// fold used to add that saturated value with a plain trapping `+` — the guard
/// handed the trap to the next line instead of removing it. Because the
/// poisoned total is then persisted to disk or CloudKit, the app crashed again
/// on every later launch.
///
/// These tests feed the exact hostile payloads from the issue through the
/// *full* accumulate path — parsing, folding, and (for CloudKit) ingress —
/// rather than only asserting on the parser the way
/// `CostScanCollaboratorTests.testIntSurvivesNonFiniteAndOutOfRangeDoubles`
/// does. That gap is exactly why the trap was missed originally.
final class CostAccumulationSafetyTests: XCTestCase {
    // MARK: - SafeAccumulate (the shared helper)

    func testAddSaturatesAtTheIntBoundsInsteadOfTrapping() {
        XCTAssertEqual(SafeAccumulate.add(Int.max, 1), Int.max)
        XCTAssertEqual(SafeAccumulate.add(Int.min, -1), Int.min)
        XCTAssertEqual(SafeAccumulate.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(SafeAccumulate.add(Int.min, Int.min), Int.min)
        XCTAssertEqual(SafeAccumulate.add(2, 3), 5)
        XCTAssertEqual(SafeAccumulate.add(-2, -3), -5)
    }

    func testAccumulateIsTheInPlaceFormOfAdd() {
        var total = Int.max - 1
        SafeAccumulate.accumulate(&total, 5)
        XCTAssertEqual(total, Int.max)
    }

    func testSumNeverTrapsRegardlessOfHowManyTermsAreAlreadySaturated() {
        XCTAssertEqual(SafeAccumulate.sum([Int.max, Int.max, Int.max, Int.max]), Int.max)
        XCTAssertEqual(SafeAccumulate.sum([1, 2, 3]), 6)
        XCTAssertEqual(SafeAccumulate.sum([]), 0)
    }

    func testIsSaturatedIdentifiesExactlyTheBoundsCostScanValuesIntProduces() {
        XCTAssertTrue(SafeAccumulate.isSaturated(Int.max))
        XCTAssertTrue(SafeAccumulate.isSaturated(Int.min))
        XCTAssertFalse(SafeAccumulate.isSaturated(Int.max - 1))
        XCTAssertFalse(SafeAccumulate.isSaturated(0))
    }

    /// The exact hostile pair from the issue's Grok site
    /// (`GrokCostScanner.swift:453`):
    /// `{"inputTokens":-5,"cachedReadTokens":9223372036854775807}`.
    /// `max(0, event.input - event.cached)` evaluates the subtraction first,
    /// so this pair traps before the `max(0, ...)` guard ever runs.
    func testClampedNonNegativeDifferenceClampsBeforeSubtractingNotAfter() {
        XCTAssertEqual(SafeAccumulate.clampedNonNegativeDifference(-5, Int.max), 0)
        XCTAssertEqual(SafeAccumulate.clampedNonNegativeDifference(Int.min, 5), 0)
        XCTAssertEqual(SafeAccumulate.clampedNonNegativeDifference(Int.min, Int.max), 0)
        XCTAssertEqual(SafeAccumulate.clampedNonNegativeDifference(100, 40), 60)
        XCTAssertEqual(SafeAccumulate.clampedNonNegativeDifference(40, 100), 0)
    }

    // MARK: - CostScanWindows.swift: TokenAccumulator.add / ClaudeSessionTotals.merge

    /// One saturated event folded in, then a second normal one — the exact
    /// "poisoned record, then the next normal one traps" shape from the issue,
    /// exercised directly against the shared accumulator every scanner funnels
    /// into.
    func testTokenAccumulatorAddSurvivesASaturatedEventFollowedByANormalOne() {
        var accumulator = TokenAccumulator()

        accumulator.add(input: Int.max, output: 0, cacheCreation: 0, cacheRead: 0)
        accumulator.add(input: 100, output: 50, cacheCreation: 0, cacheRead: 0)

        XCTAssertEqual(accumulator.input, Int.max)
        XCTAssertEqual(accumulator.output, 50)
    }

    func testClaudeSessionTotalsMergeSurvivesASaturatedFileFollowedByANormalOne() {
        var totals = ClaudeSessionTotals()
        totals.input = Int.max

        var other = ClaudeSessionTotals()
        other.input = 100
        other.output = 50

        totals.merge(other)

        XCTAssertEqual(totals.input, Int.max)
        XCTAssertEqual(totals.output, 50)
    }

    // MARK: - Claude: the 1e19-then-normal-record overflow

    /// `~/.claude/projects/**/*.jsonl` carrying `"input_tokens":1e19` used to
    /// saturate `totals.input` to `Int.max` (`ClaudeCostScanner.swift`'s
    /// `tally`), and the very next normal record's `+=` trapped. The fix
    /// excludes the saturated record outright, so the lifetime total must
    /// equal only the normal record's tokens.
    func testClaudeScanExcludesASaturatedRecordAndSurvivesTheNextNormalOne() throws {
        let root = try makeTemporaryDirectory(prefix: "ClaudeHostile")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        try writeClaudeTranscript(in: root, project: "www/hostile", name: "hostile.jsonl", lines: [
            claudeRawInputTokensLine(
                timestamp: "2026-06-15T10:00:00.000Z",
                messageID: "msg_1",
                requestID: "req_1",
                rawInputTokens: "1e19"
            ),
            claudeEventLine(
                timestamp: "2026-06-15T10:01:00.000Z",
                messageID: "msg_2",
                requestID: "req_2",
                input: 100,
                output: 50
            )
        ])

        let windows = ClaudeCostScanner.scanRoots(
            [root],
            session: CostScanSession(cutoff: cutoff, options: .unlimited)
        )

        XCTAssertEqual(windows.lifetime.input, 100, "the saturated record must be excluded, not folded in")
        XCTAssertEqual(windows.lifetime.output, 50)
    }

    // MARK: - Grok: negative input with a huge (saturated) cached count

    /// The exact hostile record from the issue:
    /// `{"inputTokens":-5,"cachedReadTokens":9223372036854775807}`, run through
    /// the full scan → `makeCost` path. Before the fix, `apply`'s
    /// `max(0, event.input - event.cached)` trapped on this record outright.
    func testGrokScanSurvivesTheExactHostilePayloadFromTheIssue() throws {
        let root = try makeTemporaryDirectory(prefix: "GrokHostile")
        try writeGrokUpdates(
            in: root,
            project: "www/hostile",
            session: "session-hostile",
            lines: [
                grokTurnCompleted(at: Date(), input: -5, cachedRead: Int.max, output: 0, reasoning: 0, ticks: 0)
            ]
        )
        let session = CostScanSession(cutoff: CostWindow.start(days: 30), options: .unlimited)

        let windows = GrokCostScanner.scanRoots([root], session: session)

        // The record is corrupt input (a saturated field) — excluded, not
        // folded into a total, and above all: no trap.
        XCTAssertNil(GrokCostScanner.makeCost(from: windows.lifetime))
    }

    /// The same shape, but with a large cached count that is *not* the exact
    /// saturation sentinel, so it survives the corruption filter and reaches
    /// the subtraction clamp itself.
    func testGrokScanClampsANegativeInputAgainstALargeButUnsaturatedCachedCount() throws {
        let root = try makeTemporaryDirectory(prefix: "GrokNegativeInput")
        try writeGrokUpdates(
            in: root,
            project: "www/hostile",
            session: "session-negative",
            lines: [
                grokTurnCompleted(at: Date(), input: -5, cachedRead: 5_000, output: 10, reasoning: 0, ticks: 1_000)
            ]
        )
        let session = CostScanSession(cutoff: CostWindow.start(days: 30), options: .unlimited)

        let windows = GrokCostScanner.scanRoots([root], session: session)
        let cost = try XCTUnwrap(GrokCostScanner.makeCost(from: windows.lifetime)).0

        XCTAssertEqual(cost.inputTokens, 0, "clamped, not a huge negative-turned-wraparound value")
    }

    // MARK: - Codex: the same shape at CodexCostScanner's subtraction site

    func testCodexScanSurvivesAHostilePayloadWithANegativeInputAndSaturatedCached() throws {
        let directory = try makeTemporaryDirectory(prefix: "CodexHostile")
        try writeCodexRollout(in: directory, path: "hostile.jsonl", lines: [
            codexRawTokenLine(
                timestamp: "2026-06-16T10:00:00Z",
                conversationID: "conv-hostile",
                rawInputTokens: "-5",
                rawCachedInputTokens: "9223372036854775807",
                rawOutputTokens: "0",
                rawReasoningTokens: "0"
            )
        ])

        var windows = CostScanWindowContext.scanWindows(
            cutoff: try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        )
        CostScanFixtureScan.codexRollouts(in: directory, windows: &windows)

        XCTAssertEqual(windows.lifetime.totals.input, 0, "the saturated record must be excluded, not folded in")
    }

    /// `CodexTokenCounters.adding` sums clamped-but-unbounded counters and the
    /// result is persisted in `cumulativeUsageBySession`, so a plain `+`
    /// traps once and then again on every later refresh that reads the
    /// poisoned cache back.
    func testCodexTokenCountersAddingSaturatesRatherThanTrappingOnPersistedCumulativeCounters() {
        var poisoned = CodexTokenCounters()
        poisoned.input = Int.max
        poisoned.output = 100
        var normal = CodexTokenCounters()
        normal.input = 1
        normal.output = 50

        let sum = poisoned.adding(normal)

        XCTAssertEqual(sum.input, Int.max)
        XCTAssertEqual(sum.output, 150)
    }

    // MARK: - Codex: makeCost combining two already-saturated totals (issue #568)

    /// `CostScanWindowContext.totals` is a `TokenAccumulator` whose individual
    /// fields each saturate independently (`TokenAccumulator.add`), but never
    /// combine with each other. `CodexCostScanner.makeCost` is the first place
    /// `output` and `reasoning` — each already possibly `Int.max` — are added
    /// together, and the first place `input` and `cacheRead` are subtracted.
    /// Both used a plain operator before issue #568.
    func testCodexMakeCostSurvivesOutputAndReasoningBothIndependentlySaturated() {
        var context = CostScanWindowContext(
            earliestDate: Date(timeIntervalSince1970: 0),
            latestDate: Date(timeIntervalSince1970: 1)
        )
        context.totals.add(input: 100, output: Int.max, cacheCreation: 0, cacheRead: 0, reasoning: 100)
        context.sessionIDs = ["session-hostile"]

        let result = CodexCostScanner.makeCost(from: context)

        XCTAssertEqual(result?.0.outputTokens, Int.max, "output + reasoning must saturate, not trap")
    }

    /// Same window, but `input` is already saturated and `cacheRead` is a huge
    /// (non-saturated) value — the exact "clamp before subtracting" shape
    /// `apply`'s own event-level guard documents, now asserted at `makeCost`.
    func testCodexMakeCostClampsBillableInputWhenCacheReadExceedsSaturatedInput() {
        var context = CostScanWindowContext(
            earliestDate: Date(timeIntervalSince1970: 0),
            latestDate: Date(timeIntervalSince1970: 1)
        )
        context.totals.add(input: Int.max, output: 10, cacheCreation: 0, cacheRead: Int.max, reasoning: 0)
        context.sessionIDs = ["session-hostile"]

        let result = CodexCostScanner.makeCost(from: context)

        XCTAssertEqual(result?.0.inputTokens, 0, "clamped, not a trapping subtraction of two saturated values")
    }

    // MARK: - TokenUsageAggregator: the same combine, shared by every scanner (issue #568)

    func testMakeDailyUsageSurvivesOutputAndReasoningBothIndependentlySaturated() {
        var tokens = TokenAccumulator()
        tokens.add(input: 10, output: Int.max, cacheCreation: 0, cacheRead: 0, reasoning: 50)
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        let daily = TokenUsageAggregator.makeDailyUsage(
            from: [day: tokens],
            provider: .codexCli,
            pricing: TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)
        )

        XCTAssertEqual(daily.first?.outputTokens, Int.max)
    }

    func testMakeBreakdownsSurvivesOutputAndReasoningBothIndependentlySaturated() {
        var tokens = TokenAccumulator()
        tokens.add(input: 10, output: Int.max, cacheCreation: 0, cacheRead: 0, reasoning: 50)

        let breakdowns = TokenUsageAggregator.makeBreakdowns(
            from: ["gpt-5.5": tokens],
            provider: .codexCli,
            pricing: TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)
        )

        XCTAssertEqual(breakdowns.first?.outputTokens, Int.max)
    }

    // MARK: - TokenCost.swift: the remaining aggregation boundaries (issue #568)

    /// `ProviderDailyTotal.totalTokens` combines three already-summed fields.
    func testProviderDailyTotalTotalTokensSurvivesTwoSaturatedFields() {
        let total = ProviderDailyTotal(
            provider: .claudeCode,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheReadTokens: 10,
            estimatedCostUSD: 1
        )

        XCTAssertEqual(total.totalTokens, Int.max)
    }

    /// `CostSummary.dailyCostWindow` reduces many `DailyTokenUsage` rows per
    /// provider with a plain `reduce(0, +)` before issue #568 — each row's own
    /// token fields can already be saturated from an earlier corrupt scan.
    func testDailyCostWindowSurvivesMultipleRowsEachCarryingASaturatedField() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let summary = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: today,
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                ),
                DailyTokenUsage(
                    date: yesterday,
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                )
            ]
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertEqual(window.providers.first?.inputTokens, Int.max)
        XCTAssertEqual(window.totalTokens, Int.max)
    }

    /// `CostSummary.filtered` sums each remaining `TokenCost.totalTokens` with
    /// a plain `+` before issue #568 — every one of those can already be
    /// saturated (`TokenCost.totalTokens` itself saturates, but combining two
    /// saturated totals is a second, separate trap site).
    func testFilteredCostSummarySurvivesMultipleAlreadySaturatedProviderTotals() {
        let cost = { (provider: ServiceType) in
            TokenCost(
                provider: provider,
                inputTokens: Int.max,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 1,
                sessionCount: 1,
                periodStart: Date(timeIntervalSince1970: 0),
                periodEnd: Date(timeIntervalSince1970: 1)
            )
        }
        let summary = CostSummary(
            costs: [cost(.claudeCode), cost(.codexCli)],
            totalCostUSD: 2,
            totalTokens: Int.max,
            periodDays: 30
        )

        let filtered = summary.filtered(to: [.claudeCode, .codexCli])

        XCTAssertEqual(filtered.totalTokens, Int.max)
    }

    /// `dailyCostWindow`'s model-breakdown merge (`TokenUsageBreakdownAggregation.merge`)
    /// folds two days' worth of the same model name together with a plain `+`
    /// before issue #568.
    func testDailyCostWindowModelBreakdownMergeSurvivesTwoSaturatedRowsSharingAName() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let model = TokenUsageBreakdown(
            provider: .claudeCode,
            name: "claude-sonnet-4-5",
            inputTokens: Int.max,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1,
            sessionCount: 1
        )
        let summary = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: today,
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1,
                    modelBreakdowns: [model]
                ),
                DailyTokenUsage(
                    date: yesterday,
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1,
                    modelBreakdowns: [model]
                )
            ]
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertEqual(window.providers.first?.modelBreakdowns?.first?.inputTokens, Int.max)
    }

    // MARK: - CLIJSONOutput: rolled-up model breakdowns across providers (issue #568)

    /// `meterbar cost --json`'s `models` field rolls up each provider's model
    /// breakdowns by name (`ModelBreakdown.merge`) — reading persisted
    /// `TokenCost` data straight back, exactly the shape `SafeAccumulate`'s own
    /// doc comment names as the original crash's second life.
    func testCLIJSONRolledUpModelsSurviveTwoProvidersSharingAModelNameBothSaturated() throws {
        let sharedModel = TokenUsageBreakdown(
            provider: .claudeCode,
            name: "shared-model",
            inputTokens: Int.max,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1,
            sessionCount: 1
        )
        let costs = [ServiceType.claudeCode, .codexCli].map { provider in
            TokenCost(
                provider: provider,
                inputTokens: Int.max,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 1,
                sessionCount: 1,
                periodStart: Date(timeIntervalSince1970: 0),
                periodEnd: Date(timeIntervalSince1970: 1),
                modelBreakdowns: [sharedModel]
            )
        }
        let cache = CostSummaryCache(
            summary: CostSummary(costs: costs, totalCostUSD: 2, totalTokens: Int.max, periodDays: 30),
            lastScanDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // Must not trap building or encoding the response.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CostCLIJSONResponse(cache: cache).jsonData()) as? [String: Any]
        )
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])

        XCTAssertEqual(models.first?["inputTokens"] as? Int, Int.max)
    }

    // MARK: - ICloudUsageAggregation: the #572 window-token aggregation path (issue #568)

    /// `CostSummary.dailyCostWindow`'s `totalTokensIncludingCacheCreation`
    /// (added by #572, the dashboard headline for every window) sums every
    /// windowed row's own `totalTokens` — each of which can already be
    /// saturated.
    func testTotalTokensIncludingCacheCreationSurvivesMultipleSaturatedRows() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let summary = CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: today,
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheCreationTokens: Int.max,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                ),
                DailyTokenUsage(
                    date: yesterday,
                    provider: .codexCli,
                    inputTokens: Int.max,
                    outputTokens: 0,
                    cacheCreationTokens: Int.max,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1
                )
            ]
        )

        let window = summary.dailyCostWindow(lastDays: 7, now: now, calendar: calendar)

        XCTAssertEqual(window.totalTokensIncludingCacheCreation, Int.max)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    // MARK: - Persisted saturated row: the crash that moved to the Costs page

    /// A saturated field persisted to `cost-summary-v2.json` (or read from an
    /// older cache written before this fix) must not trap when the Costs
    /// page, the heatmap, or `meterbar cost --json` reads `totalTokens` back.
    func testPersistedSaturatedTokenCostRowDoesNotTrapReadingItsTotal() {
        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: Int.max,
            outputTokens: 100,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 1,
            sessionCount: 1,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(cost.totalTokens, Int.max)
    }

    func testPersistedSaturatedDailyTokenUsageRowDoesNotTrapReadingItsTotal() {
        let daily = DailyTokenUsage(
            date: Date(timeIntervalSince1970: 0),
            provider: .codexCli,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheReadTokens: 10,
            estimatedCostUSD: 1
        )

        // Four fields, two already at `Int.max`: a plain `+` chain traps on
        // the very first addition.
        XCTAssertEqual(daily.totalTokens, Int.max)
    }

    // MARK: - DailyUsageChart.swift: the Costs-page daily breakdown (issue #575)

    /// The highest-visibility site of the class #573 left open: this reads
    /// `dailyUsage` cache rows directly and re-folds them on every render of
    /// the Costs page, so a single poisoned row crashes the page rather than
    /// only the scan that produced it.
    func testDailyBreakdownProviderSummariesSurviveTwoSaturatedRowsForOneProvider() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            saturatedDailyUsage(on: day, provider: .claudeCode),
            saturatedDailyUsage(on: day, provider: .claudeCode)
        ]

        let summaries = DailyUsageBreakdownList.providerSummaries(from: rows)

        let claude = try? XCTUnwrap(summaries.first { $0.provider == .claudeCode })
        XCTAssertEqual(claude?.inputTokens, Int.max)
        XCTAssertEqual(claude?.outputTokens, Int.max)
        XCTAssertEqual(claude?.cacheReadTokens, Int.max)
    }

    /// `DailyProviderUsageSummary.totalTokens` combines three fields that are
    /// each already a saturating sum over that provider's rows.
    func testDailyProviderUsageSummaryTotalTokensSurvivesTwoSaturatedFields() {
        let summary = DailyProviderUsageSummary(
            provider: .codexCli,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheReadTokens: 10,
            estimatedCostUSD: 1
        )

        XCTAssertEqual(summary.totalTokens, Int.max)
    }

    /// One row per provider, both saturated: the per-day rollup folds two
    /// already-saturated summaries.
    func testDailyProviderUsageDayTotalsSurviveTwoSaturatedProviderSummaries() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let usageDay = DailyProviderUsageDay(
            date: day,
            providers: [
                DailyProviderUsageSummary(
                    provider: .claudeCode,
                    inputTokens: Int.max,
                    outputTokens: Int.max,
                    cacheReadTokens: Int.max,
                    estimatedCostUSD: 1
                ),
                DailyProviderUsageSummary(
                    provider: .codexCli,
                    inputTokens: Int.max,
                    outputTokens: Int.max,
                    cacheReadTokens: Int.max,
                    estimatedCostUSD: 1
                )
            ]
        )

        XCTAssertEqual(usageDay.inputTokens, Int.max)
        XCTAssertEqual(usageDay.outputTokens, Int.max)
        XCTAssertEqual(usageDay.cacheReadTokens, Int.max)
        XCTAssertEqual(usageDay.totalTokens, Int.max)
    }

    /// The stacked-bar chart above the breakdown list folds the same rows.
    /// Two rows for `claudeCode` exercise the inner per-provider fold
    /// (`buildDays`' `tokens = SafeAccumulate.sum(providerRows...)`); two more
    /// for `codexCli` give the day a second segment, so `DailyUsageDay
    /// .totalTokens`'s outer fold across segments also combines two already-
    /// saturated values instead of summing a single segment against nothing.
    func testDailyUsageChartBuildDaysSurvivesTwoSaturatedProviderSegmentsOnTheSameDay() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let rows = [
            saturatedDailyUsage(on: today, provider: .claudeCode),
            saturatedDailyUsage(on: today, provider: .claudeCode),
            saturatedDailyUsage(on: today, provider: .codexCli),
            saturatedDailyUsage(on: today, provider: .codexCli)
        ]

        let days = DailyUsageChart.buildDays(from: rows, daysToShow: 7, now: now, calendar: calendar)

        let todayColumn = days.first { calendar.startOfDay(for: $0.date) == today }
        XCTAssertEqual(todayColumn?.segments.count, 2)
        XCTAssertEqual(todayColumn?.totalTokens, Int.max)
    }

    // MARK: - TokenActivityCalendar.swift: the heatmap (issue #575)

    /// Two rows for `claudeCode` on `today` exercise `providerTotals`' own
    /// inner fold (one row per provider per bucket was not enough to combine
    /// two already-saturated rows there); `codexCli` on the same day exercises
    /// the middle fold across providers within a day; `claudeCode` again on
    /// `yesterday` exercises the outer fold across days in `totalTokens`.
    func testActivityCalendarSurvivesMultipleSaturatedRowsOnTheSameDay() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let summary = CostSummary(
            costs: [],
            totalCostUSD: 1,
            totalTokens: Int.max,
            periodDays: 30,
            dailyUsage: [
                saturatedDailyUsage(on: today, provider: .claudeCode),
                saturatedDailyUsage(on: today, provider: .claudeCode),
                saturatedDailyUsage(on: today, provider: .codexCli),
                saturatedDailyUsage(
                    on: CalendarDayStep.day(today, offsetBy: -1, calendar: calendar),
                    provider: .claudeCode
                )
            ]
        )

        let grid = TokenActivityCalendar(summary: summary, weeks: 4, now: now, calendar: calendar)

        XCTAssertEqual(grid.totalTokens, Int.max)
        XCTAssertEqual(grid.day(on: today)?.totalTokens, Int.max)
        XCTAssertEqual(
            grid.day(on: today)?.providers.first { $0.provider == .claudeCode }?.tokens,
            Int.max
        )
    }

    /// Two `claudeCode` rows in the same hour exercise the hourly
    /// `providerTotals`' own inner fold (one active hour, one row per
    /// provider, was not enough to combine two already-saturated rows
    /// there); `codexCli` in the same hour exercises the middle fold across
    /// providers within an hour; a second active hour exercises the outer
    /// fold across hours in `totalTokens` (a single active hour cannot —
    /// reverting that fold to trapping addition would still sum one
    /// saturated value against a run of zeros and never trap).
    func testActivityHourlyCalendarSurvivesMultipleSaturatedRowsInTheSameHourAndAcrossHours() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let hour = today.addingTimeInterval(3_600)
        let secondHour = today.addingTimeInterval(2 * 3_600)
        let hourly = [
            HourlyTokenUsage(
                date: hour,
                provider: .claudeCode,
                inputTokens: Int.max,
                outputTokens: Int.max,
                cacheReadTokens: Int.max,
                estimatedCostUSD: 1
            ),
            HourlyTokenUsage(
                date: hour,
                provider: .claudeCode,
                inputTokens: Int.max,
                outputTokens: Int.max,
                cacheReadTokens: Int.max,
                estimatedCostUSD: 1
            ),
            HourlyTokenUsage(
                date: hour,
                provider: .codexCli,
                inputTokens: Int.max,
                outputTokens: Int.max,
                cacheReadTokens: Int.max,
                estimatedCostUSD: 1
            ),
            HourlyTokenUsage(
                date: secondHour,
                provider: .claudeCode,
                inputTokens: Int.max,
                outputTokens: Int.max,
                cacheReadTokens: Int.max,
                estimatedCostUSD: 1
            )
        ]

        let grid = TokenActivityHourlyCalendar(hourlyUsage: hourly, now: now, calendar: calendar)

        XCTAssertEqual(grid.totalTokens, Int.max)
        XCTAssertEqual(grid.hour(at: hour)?.totalTokens, Int.max)
        XCTAssertEqual(grid.hour(at: secondHour)?.totalTokens, Int.max)
        XCTAssertEqual(
            grid.hour(at: hour)?.providers.first { $0.provider == .claudeCode }?.tokens,
            Int.max
        )
    }

    // MARK: - OptimizationInsights.swift: the insights rollups (issue #575)

    /// Every fold in the initializer runs over already-saturating per-row
    /// totals: the flattened model/origin breakdowns, the four token buckets,
    /// the cache denominator, the premium share, and the 7/30-day windows.
    func testOptimizationInsightsSurviveTwoSaturatedProvidersAndBreakdowns() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let summary = CostSummary(
            costs: [
                saturatedTokenCost(provider: .claudeCode, model: "claude-opus-5"),
                saturatedTokenCost(provider: .codexCli, model: "gpt-5.5")
            ],
            totalCostUSD: 2,
            totalTokens: Int.max,
            periodDays: 30,
            dailyUsage: [
                saturatedDailyUsage(on: today, provider: .claudeCode),
                saturatedDailyUsage(on: today, provider: .codexCli)
            ]
        )

        let insights = OptimizationInsights(summary: summary, now: now, calendar: calendar)

        XCTAssertEqual(insights.tokens7Day, Int.max)
        XCTAssertEqual(insights.tokens30Day, Int.max)
        XCTAssertEqual(insights.totalTokens, Int.max)
        // Two saturated model rows, one premium: the share stays a real
        // fraction rather than trapping on the way to the denominator.
        XCTAssertGreaterThanOrEqual(insights.premiumTokenShare, 0)
        XCTAssertLessThanOrEqual(insights.premiumTokenShare, 1)
    }

    func testPremiumShareSurvivesTwoSaturatedModelRowsWithoutAGroupTotal() {
        let models = [
            saturatedBreakdown(provider: .claudeCode, name: "claude-opus-5"),
            saturatedBreakdown(provider: .claudeCode, name: "claude-haiku-4-5")
        ]

        let share = OptimizationInsights.premiumShare(of: models)

        XCTAssertGreaterThanOrEqual(share, 0)
        XCTAssertLessThanOrEqual(share, 1)
    }

    // MARK: - SocialShareCardContent.swift: the share-card sparkline (issue #575)

    func testSocialShareDailyTotalsSurviveTwoSaturatedRowsOnTheSameDay() {
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)

        let totals = SocialShareCardContent.dailyTokenTotals(
            from: [
                saturatedDailyUsage(on: today, provider: .claudeCode),
                saturatedDailyUsage(on: today, provider: .codexCli)
            ],
            days: 7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(totals.last, Int.max)
        XCTAssertEqual(totals.count, 7)
    }

    // MARK: - Fixtures
    // MARK: Saturated-row fixtures (issue #575)

    private func saturatedDailyUsage(on date: Date, provider: ServiceType) -> DailyTokenUsage {
        DailyTokenUsage(
            date: date,
            provider: provider,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheCreationTokens: Int.max,
            cacheReadTokens: Int.max,
            estimatedCostUSD: 1
        )
    }

    private func saturatedBreakdown(provider: ServiceType, name: String) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            provider: provider,
            name: name,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheCreationTokens: Int.max,
            cacheReadTokens: Int.max,
            estimatedCostUSD: 1,
            sessionCount: 1
        )
    }

    private func saturatedTokenCost(provider: ServiceType, model: String) -> TokenCost {
        TokenCost(
            provider: provider,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheCreationTokens: Int.max,
            cacheReadTokens: Int.max,
            estimatedCostUSD: 1,
            sessionCount: 1,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 1),
            modelBreakdowns: [saturatedBreakdown(provider: provider, name: model)],
            originBreakdowns: [saturatedBreakdown(provider: provider, name: "interactive")]
        )
    }


    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: Claude fixtures

    private func encodedProjectDirectory(for project: String) -> String {
        let home = ServiceSupport.realHomeDirectory()
        let encodedHome = "-" + home.split(separator: "/").joined(separator: "-")
        return encodedHome + "-" + project.replacingOccurrences(of: "/", with: "-")
    }

    private func writeClaudeTranscript(in root: URL, project: String, name: String, lines: [String]) throws {
        let directory = root.appendingPathComponent(encodedProjectDirectory(for: project), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func claudeEventLine(
        timestamp: String,
        messageID: String,
        requestID: String,
        input: Int,
        output: Int
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "requestId": "\(requestID)", "message": {"id": "\(messageID)", \
        "model": "claude-sonnet-4-5", "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    /// Same envelope, but with `input_tokens` written verbatim so a raw JSON
    /// number like `1e19` — unrepresentable as a Swift `Int` literal — can be
    /// embedded exactly as a hostile third-party writer would.
    private func claudeRawInputTokensLine(
        timestamp: String,
        messageID: String,
        requestID: String,
        rawInputTokens: String
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "requestId": "\(requestID)", "message": {"id": "\(messageID)", \
        "model": "claude-sonnet-4-5", "usage": {"input_tokens": \(rawInputTokens), "output_tokens": 0, \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    // MARK: Grok fixtures

    private func writeGrokUpdates(in root: URL, project: String, session: String, lines: [String]) throws {
        let home = ServiceSupport.realHomeDirectory()
        let encoded = "\(home)/\(project)"
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? project
        let directory = root
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("updates.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func grokTurnCompleted(
        at date: Date,
        input: Int,
        cachedRead: Int,
        output: Int,
        reasoning: Int,
        ticks: Int
    ) -> String {
        let usage = """
            {"inputTokens":\(input),"outputTokens":\(output),"cachedReadTokens":\(cachedRead),\
            "reasoningTokens":\(reasoning),"modelCalls":1,"apiDurationMs":1234,"costUsdTicks":\(ticks),"numTurns":1}
            """
        return """
            {"timestamp":\(Int(date.timeIntervalSince1970)),"method":"session/update",\
            "params":{"sessionId":"019fafec-972e-7413-8cbd-01647988c8f9",\
            "update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn","usage":\(usage)}}}
            """
    }

    // MARK: Codex fixtures

    private func writeCodexRollout(in root: URL, path: String, lines: [String]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Token counts written verbatim so a hostile value like the exact
    /// `Int.max` sentinel can be embedded without going through a Swift `Int`
    /// literal.
    private func codexRawTokenLine(
        timestamp: String,
        conversationID: String,
        rawInputTokens: String,
        rawCachedInputTokens: String,
        rawOutputTokens: String,
        rawReasoningTokens: String
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"model": "gpt-5.5", "last_token_usage": \
        {"input_tokens": \(rawInputTokens), "output_tokens": \(rawOutputTokens), \
        "cached_input_tokens": \(rawCachedInputTokens), "reasoning_output_tokens": \(rawReasoningTokens)}}}}
        """
    }
}
