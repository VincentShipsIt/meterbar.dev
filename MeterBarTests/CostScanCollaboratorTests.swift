import XCTest
@testable import MeterBar
import MeterBarShared

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

    // MARK: - CostSummaryBuilder

    func testSummaryWithEveryProviderDisabledScansNothingAndStaysEmpty() {
        let summary = CostSummaryBuilder.makeSummary(
            days: 7,
            includeClaudeCode: false,
            includeCodexCli: false,
            claudeAccounts: []
        )

        XCTAssertTrue(summary.costs.isEmpty)
        XCTAssertTrue(summary.dailyUsage.isEmpty)
        XCTAssertEqual(summary.totalCostUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertEqual(summary.periodDays, 7)
    }
}
