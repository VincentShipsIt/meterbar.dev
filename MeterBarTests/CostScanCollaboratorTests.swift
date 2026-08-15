import XCTest
@testable import MeterBar
import MeterBarShared
import SQLite3

/// Contract tests for the collaborators split out of `CostTracker` (audit C1d).
///
/// Nearly all of this arithmetic was `private` on a 1,018-line class, so it was
/// unreachable from a test: the only way in was a full filesystem scan. Pulling
/// the scan into named namespaces makes each step directly assertable.
final class CostScanCollaboratorTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    // MARK: - CostWindow

    func testWindowStartIsInclusiveOfToday() {
        let calendar = utcCalendar
        let now = FlexibleISO8601.date(from: "2026-07-25T18:00:00Z")!

        let start = CostWindow.start(days: 30, now: now, calendar: calendar)

        // 30 days means today plus the previous 29 — Jun 26, not Jun 25. A
        // rolling 720-hour interval would spill into a 31st date bucket.
        let expected = calendar.startOfDay(for: FlexibleISO8601.date(from: "2026-06-26T00:00:00Z")!)
        XCTAssertEqual(start, expected)
    }

    func testWindowStartClampsNonPositiveDaysToToday() {
        let calendar = utcCalendar
        let now = FlexibleISO8601.date(from: "2026-07-25T18:00:00Z")!
        let today = calendar.startOfDay(for: now)

        XCTAssertEqual(CostWindow.start(days: 1, now: now, calendar: calendar), today)
        XCTAssertEqual(CostWindow.start(days: 0, now: now, calendar: calendar), today)
        XCTAssertEqual(CostWindow.start(days: -5, now: now, calendar: calendar), today)
    }

    // MARK: - CostScanValues

    func testIntCoercesEveryJSONNumberRepresentation() {
        XCTAssertEqual(CostScanValues.int(42), 42)
        XCTAssertEqual(CostScanValues.int(Int64(42)), 42)
        XCTAssertEqual(CostScanValues.int(42.9), 42)
        XCTAssertEqual(CostScanValues.int("42"), 42)
        XCTAssertEqual(CostScanValues.int("not a number"), 0)
        XCTAssertEqual(CostScanValues.int(nil), 0)
    }

    /// The scan reads on-disk JSONL written by third-party CLIs, so a doubles
    /// path that traps would crash the whole refresh on one malformed line.
    func testIntSurvivesNonFiniteAndOutOfRangeDoubles() {
        XCTAssertEqual(CostScanValues.int(Double.nan), 0)
        XCTAssertEqual(CostScanValues.int(Double.infinity), Int.max)
        XCTAssertEqual(CostScanValues.int(-Double.infinity), Int.min)
        XCTAssertEqual(CostScanValues.int(1e30), Int.max)
        XCTAssertEqual(CostScanValues.int(-1e30), Int.min)
        XCTAssertEqual(CostScanValues.int(-42.9), -42)
    }

    func testDisplayModelNameNormalizesAndLabelsBlanks() {
        XCTAssertEqual(CostScanValues.displayModelName("claude-opus-4-8-20260101"), "claude-opus-4-8")
        XCTAssertEqual(CostScanValues.displayModelName("  "), "Unknown model")
        XCTAssertEqual(CostScanValues.displayModelName(nil), "Unknown model")
    }

    func testDisplayOriginNameTitleCasesRealOriginatorSlugs() {
        XCTAssertEqual(CostScanValues.displayOriginName("codex_exec"), "Codex Exec")
        XCTAssertEqual(CostScanValues.displayOriginName("codex-desktop"), "Codex Desktop")
        XCTAssertEqual(CostScanValues.displayOriginName("Codex CLI"), "Codex CLI")
        XCTAssertEqual(CostScanValues.displayOriginName("  "), "Unknown origin")
        XCTAssertEqual(CostScanValues.displayOriginName(nil), "Unknown origin")
    }

    // MARK: - CostScanFileSystem

    func testIsLocalDirectoryRejectsFilesAndMissingPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanFS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(CostScanFileSystem.isLocalDirectory(root))
        XCTAssertFalse(CostScanFileSystem.isLocalDirectory(file))
        XCTAssertFalse(CostScanFileSystem.isLocalDirectory(root.appendingPathComponent("gone", isDirectory: true)))
    }

    // MARK: - TokenCostMath

    func testCalculateCostPricesEveryTokenClassPerMillion() {
        let pricing = TokenPricing(input: 1.0, output: 10.0, cacheCreation: 2.0, cacheRead: 0.5)

        let cost = TokenCostMath.calculateCost(
            input: 1_000_000,
            output: 1_000_000,
            cacheCreation: 1_000_000,
            cacheRead: 1_000_000,
            pricing: pricing
        )

        XCTAssertEqual(cost, 13.5, accuracy: 0.0001)
    }

    func testCalculateCostClampsNegativeCountsToZero() {
        let pricing = TokenPricing(input: 1.0, output: 10.0, cacheCreation: 2.0, cacheRead: 0.5)

        let cost = TokenCostMath.calculateCost(
            input: -1_000_000,
            output: -1_000_000,
            cacheCreation: -1_000_000,
            cacheRead: -1_000_000,
            pricing: pricing
        )

        XCTAssertEqual(cost, 0, accuracy: 0.0001)
    }

    func testClaudeCostSplitsTheOneHourCacheTierAtItsOwnRate() {
        let pricing = TokenPricing(
            input: 0, output: 0, cacheCreation: 1.0, cacheRead: 0, cacheCreationOneHour: 4.0
        )

        let cost = TokenCostMath.calculateClaudeCost(
            input: 0,
            output: 0,
            cacheCreation: 1_000_000,
            cacheCreationOneHour: 250_000,
            cacheRead: 0,
            pricing: pricing
        )

        // 750k at the five-minute rate plus 250k at the one-hour rate.
        XCTAssertEqual(cost, 0.75 + 1.0, accuracy: 0.0001)
    }

    func testClaudeCostFallsBackToTheFiveMinuteRateWhenNoOneHourRateExists() {
        let pricing = TokenPricing(input: 0, output: 0, cacheCreation: 2.0, cacheRead: 0)

        let cost = TokenCostMath.calculateClaudeCost(
            input: 0,
            output: 0,
            cacheCreation: 1_000_000,
            cacheCreationOneHour: 1_000_000,
            cacheRead: 0,
            pricing: pricing
        )

        XCTAssertEqual(cost, 2.0, accuracy: 0.0001)
    }

    // MARK: - TokenAccumulator

    func testAccumulatorAddCountsOneEventByDefault() {
        var accumulator = TokenAccumulator()
        accumulator.add(input: 10, output: 5, cacheCreation: 1, cacheRead: 2)

        XCTAssertEqual(accumulator.input, 10)
        XCTAssertEqual(accumulator.output, 5)
        XCTAssertEqual(accumulator.reasoning, 0)
        XCTAssertEqual(accumulator.events, 1)
    }

    func testAccumulatorMergeCarriesEveryField() {
        var target = TokenAccumulator()
        target.add(
            input: 1, output: 2, cacheCreation: 3, cacheRead: 4,
            reasoning: 5, estimatedCostUSD: 6, events: 7
        )
        var other = TokenAccumulator()
        other.add(
            input: 1, output: 1, cacheCreation: 1, cacheRead: 1,
            reasoning: 1, estimatedCostUSD: 1, events: 1
        )

        target.merge(other)

        XCTAssertEqual(target.input, 2)
        XCTAssertEqual(target.output, 3)
        XCTAssertEqual(target.cacheCreation, 4)
        XCTAssertEqual(target.cacheRead, 5)
        XCTAssertEqual(target.reasoning, 6)
        XCTAssertEqual(target.estimatedCostUSD, 7, accuracy: 0.0001)
        XCTAssertEqual(target.events, 8)
    }

    // MARK: - TokenUsageAggregator

    private func totals(input: Int, output: Int, cacheRead: Int, cost: Double = 0) -> TokenAccumulator {
        var accumulator = TokenAccumulator()
        accumulator.add(
            input: input, output: output, cacheCreation: 0,
            cacheRead: cacheRead, estimatedCostUSD: cost
        )
        return accumulator
    }

    func testDailyUsageSubtractsCachedInputForCodexOnly() {
        let day = FlexibleISO8601.date(from: "2026-07-01T00:00:00Z")!
        let source = [day: totals(input: 1_000, output: 100, cacheRead: 400)]

        let codex = TokenUsageAggregator.makeDailyUsage(
            from: source, provider: .codexCli, pricing: ModelPricing.codex
        )
        let claude = TokenUsageAggregator.makeDailyUsage(
            from: source, provider: .claudeCode, pricing: ModelPricing.claude(for: nil)
        )

        // Codex reports cached tokens inside `input_tokens`; Claude reports them
        // separately, so only Codex rows subtract to reach billable input.
        XCTAssertEqual(codex.first?.inputTokens, 600)
        XCTAssertEqual(claude.first?.inputTokens, 1_000)
    }

    func testDailyUsageFoldsReasoningIntoOutput() {
        let day = FlexibleISO8601.date(from: "2026-07-01T00:00:00Z")!
        var accumulator = TokenAccumulator()
        accumulator.add(input: 10, output: 100, cacheCreation: 0, cacheRead: 0, reasoning: 25)

        let rows = TokenUsageAggregator.makeDailyUsage(
            from: [day: accumulator], provider: .codexCli, pricing: ModelPricing.codex
        )

        XCTAssertEqual(rows.first?.outputTokens, 125)
    }

    func testDailyUsagePrefersRecordedCostOverRecomputing() {
        let day = FlexibleISO8601.date(from: "2026-07-01T00:00:00Z")!
        let source = [day: totals(input: 1_000, output: 100, cacheRead: 0, cost: 12.5)]

        let rows = TokenUsageAggregator.makeDailyUsage(
            from: source, provider: .claudeCode, pricing: ModelPricing.claude(for: nil)
        )

        XCTAssertEqual(rows.first?.estimatedCostUSD ?? -1, 12.5, accuracy: 0.0001)
    }

    func testBreakdownsSortByCostThenTokens() {
        let source: [String: TokenAccumulator] = [
            "rich": totals(input: 10, output: 0, cacheRead: 0, cost: 9),
            "tied-large": totals(input: 500, output: 0, cacheRead: 0, cost: 1),
            "tied-small": totals(input: 10, output: 0, cacheRead: 0, cost: 1)
        ]

        let rows = TokenUsageAggregator.makeBreakdowns(
            from: source, provider: .claudeCode, pricing: ModelPricing.claude(for: nil)
        )

        XCTAssertEqual(rows.map(\.name), ["rich", "tied-large", "tied-small"])
    }

    func testBreakdownsPriceEachRowThroughPricingForName() {
        let source: [String: TokenAccumulator] = [
            "billed": totals(input: 1_000_000, output: 0, cacheRead: 0),
            "free": totals(input: 1_000_000, output: 0, cacheRead: 0)
        ]
        let flat = TokenPricing(input: 1.0, output: 1.0, cacheCreation: 1.0, cacheRead: 1.0)
        let free = TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)

        let rows = TokenUsageAggregator.makeBreakdowns(
            from: source,
            provider: .claudeCode,
            pricing: flat,
            pricingForName: { $0 == "free" ? free : flat }
        )

        let billed = rows.first { $0.name == "billed" }?.estimatedCostUSD ?? -1
        let unbilled = rows.first { $0.name == "free" }?.estimatedCostUSD ?? -1
        XCTAssertEqual(billed, 1.0, accuracy: 0.0001)
        XCTAssertEqual(unbilled, 0.0, accuracy: 0.0001)
    }

    func testDailyUsageResolvesEachDaysRateFromThatDayRatherThanOneSharedRate() throws {
        let cheapDay = try XCTUnwrap(FlexibleISO8601.date(from: "2026-01-10T00:00:00Z"))
        let dearDay = try XCTUnwrap(FlexibleISO8601.date(from: "2026-09-10T00:00:00Z"))
        let source = [
            cheapDay: totals(input: 1_000_000, output: 0, cacheRead: 0),
            dearDay: totals(input: 1_000_000, output: 0, cacheRead: 0)
        ]
        let cheap = TokenPricing(input: 1.0, output: 0, cacheCreation: 0, cacheRead: 0)
        let dear = TokenPricing(input: 5.0, output: 0, cacheCreation: 0, cacheRead: 0)

        let rows = TokenUsageAggregator.makeDailyUsage(
            from: source,
            provider: .codexCli,
            pricing: dear,
            modelsByDay: [cheapDay: ["sol": totals(input: 1_000_000, output: 0, cacheRead: 0)]],
            pricingAt: { _, at in at < dearDay ? cheap : dear }
        )

        XCTAssertEqual(rows.first { $0.date == cheapDay }?.estimatedCostUSD ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(rows.first { $0.date == dearDay }?.estimatedCostUSD ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(
            rows.first { $0.date == cheapDay }?.modelBreakdowns?.first?.estimatedCostUSD ?? -1,
            1.0,
            accuracy: 0.0001
        )
    }

    func testProjectBreakdownsNestTheirOwnModelSliceUnderEachRollupRow() {
        let projectTotals: [String: TokenAccumulator] = [
            "app-a": totals(input: 100, output: 0, cacheRead: 0, cost: 5),
            "app-b": totals(input: 10, output: 0, cacheRead: 0, cost: 1)
        ]
        let modelsByProject: [String: [String: TokenAccumulator]] = [
            "app-a": [
                "opus": totals(input: 80, output: 0, cacheRead: 0, cost: 4),
                "haiku": totals(input: 20, output: 0, cacheRead: 0, cost: 1)
            ]
            // "app-b" deliberately has no entry — must fall back to an empty slice.
        ]

        let rows = TokenUsageAggregator.makeProjectBreakdowns(
            from: projectTotals,
            modelsByProject: modelsByProject,
            provider: .claudeCode,
            pricing: ModelPricing.claude(for: nil)
        )

        XCTAssertEqual(rows.map(\.name), ["app-a", "app-b"])
        let appA = try! XCTUnwrap(rows.first { $0.name == "app-a" })
        XCTAssertEqual(Set(appA.modelBreakdowns.map(\.name)), ["opus", "haiku"])
        XCTAssertEqual(appA.modelBreakdowns.reduce(0) { $0 + $1.inputTokens }, appA.inputTokens)

        let appB = try! XCTUnwrap(rows.first { $0.name == "app-b" })
        XCTAssertTrue(appB.modelBreakdowns.isEmpty)
    }

    // MARK: - ClaudeCostScanner

    func testProjectsURLAppendsProjectsUnlessAlreadyPresent() {
        XCTAssertEqual(ClaudeCostScanner.projectsURL(forConfigPath: "/tmp/cfg").path, "/tmp/cfg/projects")
        XCTAssertEqual(
            ClaudeCostScanner.projectsURL(forConfigPath: " /tmp/cfg/projects ").path,
            "/tmp/cfg/projects"
        )
    }

    func testPricingDelegatesToTheSharedTable() {
        XCTAssertEqual(
            ClaudeCostScanner.pricing(for: "claude-fable-5").input,
            ModelPricing.claude(for: "claude-fable-5").input
        )
    }

    func testNormalizeModelStripsTheDateSuffix() {
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("claude-opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testOneHourCacheTokensClampToTotalCacheCreation() {
        let overstated: [String: Any] = [
            "cache_creation_input_tokens": 1_000,
            "cache_creation": ["ephemeral_1h_input_tokens": 4_000]
        ]
        let negative: [String: Any] = [
            "cache_creation_input_tokens": 1_000,
            "cache_creation": ["ephemeral_1h_input_tokens": -5]
        ]

        XCTAssertEqual(ClaudeCostScanner.oneHourCacheCreationTokens(in: overstated), 1_000)
        XCTAssertEqual(ClaudeCostScanner.oneHourCacheCreationTokens(in: negative), 0)
        // No `cache_creation` object at all: nothing is on the one-hour tier.
        XCTAssertEqual(ClaudeCostScanner.oneHourCacheCreationTokens(in: ["cache_creation_input_tokens": 10]), 0)
    }

    func testUsageOriginClassifiesSidechainsSkillsToolsAndMainChat() {
        let url = URL(fileURLWithPath: "/tmp/projects/session.jsonl")
        let readTool: [String: Any] = ["type": "tool_use", "name": "Read"]
        let skillTool: [String: Any] = ["type": "tool_use", "name": "Skill"]
        let agentTool: [String: Any] = ["type": "tool_use", "name": "Task"]

        XCTAssertEqual(
            ClaudeCostScanner.usageOrigin(json: ["isSidechain": true], message: [:], url: url),
            "Agents"
        )
        XCTAssertEqual(
            ClaudeCostScanner.usageOrigin(json: [:], message: ["content": [skillTool]], url: url),
            "Skills"
        )
        XCTAssertEqual(
            ClaudeCostScanner.usageOrigin(json: [:], message: ["content": [agentTool]], url: url),
            "Agents"
        )
        XCTAssertEqual(
            ClaudeCostScanner.usageOrigin(json: [:], message: ["content": [readTool]], url: url),
            "Tool use"
        )
        XCTAssertEqual(ClaudeCostScanner.usageOrigin(json: [:], message: [:], url: url), "Main chat")
    }

    func testUsageOriginTreatsSubagentTranscriptPathsAsAgents() {
        let url = URL(fileURLWithPath: "/tmp/projects/subagents/session.jsonl")

        XCTAssertEqual(ClaudeCostScanner.usageOrigin(json: [:], message: [:], url: url), "Agents")
    }

    // MARK: - CodexCostScanner

    func testModelNamePrefersInfoOverPayloadAndModelOverSlug() {
        XCTAssertEqual(
            CodexCostScanner.modelName(from: ["model": "a", "slug": "b"], payload: ["model": "c"]),
            "a"
        )
        XCTAssertEqual(CodexCostScanner.modelName(from: ["slug": "b"], payload: ["model": "c"]), "b")
        XCTAssertEqual(CodexCostScanner.modelName(from: [:], payload: ["model": "c"]), "c")
        XCTAssertEqual(CodexCostScanner.modelName(from: [:], payload: ["slug": "d"]), "d")
        XCTAssertNil(CodexCostScanner.modelName(from: [:], payload: [:]))
    }

    func testLogValueParsesFlatKeyValueLogBodies() {
        let body = "event.timestamp=2026-07-01T10:00:00Z input_token_count=1234 model=gpt-5.6-sol}"

        XCTAssertEqual(CodexCostScanner.logInt("input_token_count", in: body), 1_234)
        XCTAssertEqual(CodexCostScanner.logInt("missing_count", in: body), 0)
        XCTAssertEqual(CodexCostScanner.logValue("model", in: body), "gpt-5.6-sol")
        XCTAssertNil(CodexCostScanner.logValue("missing_key", in: body))
        XCTAssertEqual(
            CodexCostScanner.logDate(in: body),
            FlexibleISO8601.date(from: "2026-07-01T10:00:00Z")
        )
    }

    func testSQLiteFallbackReadsOnlyRecentOpenTelemetryUsageRows() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterbar-codex-log-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        guard let db else {
            return XCTFail("Expected a temporary SQLite database")
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                ts_nanos INTEGER NOT NULL,
                target TEXT NOT NULL,
                feedback_log_body TEXT
            );
            CREATE INDEX idx_logs_ts ON logs(ts DESC, ts_nanos DESC, id DESC);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        let recentUsage = "event.timestamp=2026-07-15T10:00:00Z input_token_count=120 "
            + "output_token_count=30 cached_token_count=20 reasoning_token_count=5 "
            + "conversation.id=recent model=gpt-5.6-sol originator=codex_exec}"
        let oldUsage = recentUsage.replacingOccurrences(of: "2026-07-15", with: "2026-06-01")
        let outputOnlyUsage = "event.timestamp=2026-07-16T10:00:00Z output_token_count=7 "
            + "conversation.id=output-only model=gpt-5.6-sol originator=codex_exec}"
        let inserts = [
            "INSERT INTO logs(ts, ts_nanos, target, feedback_log_body) "
                + "VALUES(1784110000, 0, 'codex_otel.trace_safe', '\(recentUsage)');",
            "INSERT INTO logs(ts, ts_nanos, target, feedback_log_body) "
                + "VALUES(1784196000, 0, 'codex_otel.trace_safe', '\(outputOnlyUsage)');",
            // Diagnostic bodies can contain copied parser text. A non-OTel
            // producer must never be interpreted as a usage event.
            "INSERT INTO logs(ts, ts_nanos, target, feedback_log_body) "
                + "VALUES(1784110001, 0, 'codex_core::stream_events_utils', '\(recentUsage)');",
            "INSERT INTO logs(ts, ts_nanos, target, feedback_log_body) "
                + "VALUES(1780270000, 0, 'codex_otel.trace_safe', '\(oldUsage)');",
        ]
        for insert in inserts {
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }

        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-01T00:00:00Z"))
        var windows = CostScanWindowContext.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanSQLiteLogs(database: database, since: cutoff, windows: &windows)

        XCTAssertEqual(windows.period.totals.input, 120)
        XCTAssertEqual(windows.period.totals.output, 37)
        XCTAssertEqual(windows.period.totals.cacheRead, 20)
        XCTAssertEqual(windows.period.totals.reasoning, 5)
        XCTAssertEqual(windows.period.sessionIDs, ["output-only", "recent"])
        XCTAssertEqual(windows.lifetime.totals.input, 120)
    }

    /// Issue #339's invariant reaches the fallback path too: totals that carry
    /// no per-event cost must be priced at the rate in effect when they were
    /// recorded, not at today's. Exercised through an injected dated schedule
    /// because every entry in the shipped table is still open-ended backwards.
    func testCodexFallbackPricingUsesTheRateInEffectWhenTheTokensWereRecorded() throws {
        let recorded = try XCTUnwrap(FlexibleISO8601.date(from: "2026-02-10T10:00:00Z"))
        let day = Calendar.current.startOfDay(for: recorded)
        let oldRate = TokenPricing(input: 3.0, output: 0, cacheCreation: 0, cacheRead: 0)
        let newRate = TokenPricing(input: 30.0, output: 0, cacheCreation: 0, cacheRead: 0)
        let schedule = PricingSchedule([
            DatedTokenPricing(
                effectiveFrom: DatedTokenPricing.utcDay(2026, 1, 1), verifiedOn: "2026-01-05", pricing: oldRate),
            DatedTokenPricing(
                effectiveFrom: DatedTokenPricing.utcDay(2026, 6, 1), verifiedOn: "2026-06-02", pricing: newRate)
        ])

        // No `estimatedCostUSD` anywhere, so every row falls back to the table.
        let tokens = totals(input: 1_000_000, output: 0, cacheRead: 0)
        var context = CostScanWindowContext(earliestDate: recorded, latestDate: recorded)
        context.totals = tokens
        context.sessionIDs = ["session"]
        context.modelTotals = ["gpt-5.6-sol": tokens]
        context.projectTotals = ["app": tokens]
        context.projectModelTotals = ["app": ["gpt-5.6-sol": tokens]]
        context.dailyTotals = [day: tokens]
        context.dailyModelTotals = [day: ["gpt-5.6-sol": tokens]]
        context.dailyProjectTotals = [day: ["app": tokens]]
        context.dailyProjectModelTotals = [day: ["app": ["gpt-5.6-sol": tokens]]]

        let (cost, dailyRows, _) = try XCTUnwrap(
            CodexCostScanner.makeCost(from: context) { _, at in
                schedule.resolve(at: at)?.pricing ?? newRate
            }
        )
        let daily = try XCTUnwrap(dailyRows.first)

        XCTAssertEqual(cost.estimatedCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertEqual(cost.modelBreakdowns.first?.estimatedCostUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(
            cost.projectBreakdowns.first?.modelBreakdowns.first?.estimatedCostUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(daily.estimatedCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertEqual(daily.modelBreakdowns?.first?.estimatedCostUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(
            daily.projectBreakdowns?.first?.modelBreakdowns.first?.estimatedCostUSD ?? -1, 3.0, accuracy: 0.0001)
    }

    // MARK: - CostSummaryBuilder

    func testSummaryWithEveryProviderDisabledScansNothingAndStaysEmpty() {
        let days = 7
        let scan = CostSummaryBuilder.makeScan(
            days: days,
            enabledProviders: [],
            claudeAccounts: [],
            grokAccounts: [],
            session: CostScanSession(cutoff: CostWindow.start(days: days), options: .unlimited)
        )

        XCTAssertTrue(scan.summary.costs.isEmpty)
        XCTAssertTrue(scan.summary.dailyUsage.isEmpty)
        XCTAssertEqual(scan.summary.totalCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(scan.summary.totalTokens, 0)
        XCTAssertEqual(scan.summary.periodDays, days)
        // Nothing to read is not the same as running out of budget.
        XCTAssertTrue(scan.isComplete)
    }

    func testBudgetedSummaryReportsThePricingProvenanceItScannedWith() throws {
        let root = try makeCorpusDirectory()
        let config = root.appendingPathComponent("claude", isDirectory: true)
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        let project = projects
            .appendingPathComponent("fixture", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let event = """
        {"timestamp":"\(timestamp)","requestId":"request","message":{"id":"message",\
        "model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try event.write(
            to: project.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let days = 30
        let session = CostScanSession(
            cutoff: CostWindow.start(days: days),
            options: .unlimited,
            store: CostScanCacheStore(directory: cache)
        )

        let budgeted = CostSummaryBuilder.makeScan(
            days: days,
            enabledProviders: [.claude],
            claudeAccounts: [],
            grokAccounts: [],
            session: session,
            claudeProjectRoots: [projects]
        )

        let pricing = try XCTUnwrap(budgeted.summary.pricing)
        XCTAssertFalse(pricing.verificationDates.isEmpty)
        // Every event was priced from a table entry, so none predate the table.
        XCTAssertEqual(pricing.eventsBeforeFirstEntry, 0)
        XCTAssertNil(pricing.diagnosticNote)
    }

    // MARK: - CostScanBudget

    func testProductionBudgetIsBoundedPerFileAndPerRefresh() {
        let options = CostScanBudgetOptions.default

        XCTAssertEqual(options.maxBytesPerFile, 256 * 1024 * 1024)
        XCTAssertEqual(options.maxNewBytesPerRefresh, 512 * 1024 * 1024)
        XCTAssertNotNil(options.wallClock)
        XCTAssertFalse(options.isUnbounded)
        XCTAssertTrue(CostScanBudgetOptions.unlimited.isUnbounded)
    }

    func testAllowanceIsTheSmallerOfThePerFileAndRemainingRefreshBudgets() {
        let budget = CostScanBudget(
            options: CostScanBudgetOptions(maxBytesPerFile: 100, maxNewBytesPerRefresh: 250, wallClock: nil)
        )

        XCTAssertEqual(budget.allowance, 100)
        budget.consume(180)
        XCTAssertEqual(budget.bytesRead, 180)
        XCTAssertEqual(budget.allowance, 70)
        XCTAssertFalse(budget.isExhausted)

        budget.consume(70)
        XCTAssertEqual(budget.allowance, 0)
        XCTAssertTrue(budget.isExhausted)
    }

    func testUnlimitedBudgetIsNeverExhausted() {
        let budget = CostScanBudget(options: .unlimited)

        budget.consume(4 * 1024 * 1024 * 1024)

        XCTAssertFalse(budget.isExhausted)
        XCTAssertEqual(budget.allowance, Int.max)
    }

    func testWallClockBudgetExpiresIndependentlyOfBytes() {
        let options = CostScanBudgetOptions(maxBytesPerFile: .max, maxNewBytesPerRefresh: .max, wallClock: 5)
        let budget = CostScanBudget(options: options, startedAt: Date(timeIntervalSinceNow: -10))

        XCTAssertTrue(budget.isExhausted)
        XCTAssertEqual(budget.allowance, 0)
    }

    func testCancellingTheTokenExhaustsTheBudget() {
        let token = CostScanCancellationToken()
        let budget = CostScanBudget(options: .unlimited, token: token)

        XCTAssertFalse(budget.isExhausted)
        token.cancel()
        XCTAssertTrue(budget.isExhausted)
        XCTAssertTrue(budget.isCancelled)
    }

    // MARK: - CostScanCorpus

    func testTranscriptsAreOrderedNewestModifiedFirst() throws {
        let root = try makeCorpusDirectory()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "middle.jsonl", bytes: 10, modified: now.addingTimeInterval(-60))
        try writeCorpusFile(in: root, name: "oldest.jsonl", bytes: 10, modified: now.addingTimeInterval(-120))
        try writeCorpusFile(in: root, name: "newest.jsonl", bytes: 10, modified: now)
        // Only `.jsonl` transcripts participate in the scan.
        try writeCorpusFile(in: root, name: "notes.txt", bytes: 10, modified: now)

        let files = CostScanCorpus.listing(in: root).files

        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["newest.jsonl", "middle.jsonl", "oldest.jsonl"])
        XCTAssertEqual(files.first?.size, 10)
    }

    /// A root that is not there yields nothing, and says so: the walk never
    /// happened, so its emptiness is no evidence that the cached transcripts
    /// were deleted.
    func testCorpusOfAMissingDirectoryIsEmptyAndIncomplete() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanCorpus-missing-\(UUID().uuidString)", isDirectory: true)

        let listing = CostScanCorpus.listing(in: missing)

        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertFalse(listing.isComplete)
    }

    // MARK: - CostScanExecutor

    func testExecutorReturnsTheWorkResult() async throws {
        let value = try await CostScanExecutor.run { _ in 42 }

        XCTAssertEqual(value, 42)
    }

    func testCancelledWorkDoesNotWaitBehindAnInFlightScan() async throws {
        // The whole point of the serial queue is that a stale refresh can be
        // abandoned instantly: work still queued must fail fast rather than sit
        // behind a scan that is already reading the corpus.
        let gate = DispatchSemaphore(value: 0)
        let running = CostScanFlag()
        let blocker = Task {
            try await CostScanExecutor.run { _ in
                running.set()
                gate.wait()
            }
        }
        try await waitUntil(running.isSet, "the blocking scan to occupy the queue")

        let queued = Task { try await CostScanExecutor.run { _ in true } }
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("expected the queued scan to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        gate.signal()
        _ = try await blocker.value
    }

    func testCancellingAnInFlightScanSignalsItsToken() async throws {
        let started = CostScanFlag()
        let observed = CostScanFlag()
        let task = Task {
            try await CostScanExecutor.run { token in
                started.set()
                while !token.isCancelled {
                    usleep(1_000)
                }
                observed.set()
                return true
            }
        }
        // Polled rather than waited on a semaphore: this method runs on the main
        // actor, and `task` is enqueued to it too, so blocking here would starve
        // the very work we are waiting to start.
        try await waitUntil(started.isSet, "the scan to reach the queue")

        task.cancel()
        _ = try? await task.value
        // The queue is serial, so this only runs once the cancelled work returned.
        _ = try await CostScanExecutor.run { _ in true }

        XCTAssertTrue(observed.isSet)
    }

    /// Yields until `condition` holds, or fails after five seconds.
    ///
    /// Every wait in these tests has to suspend rather than block: the test
    /// methods are main-actor isolated, and so are the `Task`s they spawn, so a
    /// `DispatchSemaphore.wait` on this thread deadlocks against the work it is
    /// waiting for.
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<5_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: - Corpus fixtures

    private func makeCorpusDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanCorpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeCorpusFile(in root: URL, name: String, bytes: Int, modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: UInt8(ascii: "x"), count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

/// Lock-guarded boolean so a scan closure running on the serial queue can report
/// back to the test without tripping `Sendable` checking.
private final class CostScanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
