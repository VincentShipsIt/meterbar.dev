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

    // MARK: - Fixtures

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
