import XCTest
@testable import MeterBar
import MeterBarShared

/// First direct coverage for CostTracker's parsing/pricing internals — the
/// audit found ~1,000 lines of money math with zero tests, which is exactly
/// where the CLI-vs-app cost divergence hid.
final class CostTrackerTests: XCTestCase {
    // MARK: - Demo mode

    func testDemoModePublishesSyntheticNonAlarmingSummaryWithoutScanning() {
        let tracker = CostTracker(demoMode: true)

        let summary = tracker.costSummary
        XCTAssertNotNil(summary, "demo mode should publish a summary at construction")
        XCTAssertEqual(summary?.totalCostUSD ?? 0, 204.90, accuracy: 0.001)
        XCTAssertEqual(summary?.periodDays, 30)
        XCTAssertNil(summary?.lifetime)
        XCTAssertNotNil(tracker.lastScanDate)
        XCTAssertFalse(tracker.isScanning)

        // Never leaks real project paths or private model routing.
        for cost in summary?.costs ?? [] {
            XCTAssertTrue(cost.modelBreakdowns.isEmpty)
            XCTAssertTrue(cost.originBreakdowns.isEmpty)
        }
    }

    // MARK: - Scan outcome

    func testOnlyACompletedScanIsAuthoritative() {
        XCTAssertTrue(CostTracker.ScanOutcome.completed.isAuthoritative)
        XCTAssertFalse(CostTracker.ScanOutcome.partial.isAuthoritative)
        XCTAssertFalse(CostTracker.ScanOutcome.skipped.isAuthoritative)
    }

    func testDemoModeScanReportsThatItReadNothing() async {
        let outcome = await CostTracker(demoMode: true).scanCosts(days: 30)

        XCTAssertEqual(outcome, .skipped)
    }

    @MainActor
    func testScanReportsSkippedWhileTheBackgroundBackfillHoldsTheTracker() async {
        let tracker = CostTracker()
        tracker.isRefreshingMissingDays = true

        let outcome = await tracker.scanCosts(days: 30)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(outcome.isAuthoritative)
    }

    // MARK: - Model-id normalization

    func testNormalizeClaudeModelStripsDateSuffix() {
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("claude-opus-4-8-20260101"), "claude-opus-4-8")
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("claude-fable-5-20260315"), "claude-fable-5")
    }

    func testNormalizeClaudeModelStripsBedrockStylePrefixes() {
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("anthropic.claude-sonnet-4-5"), "claude-sonnet-4-5")
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("us.anthropic.claude-opus-4-8"), "claude-opus-4-8")
    }

    func testNormalizeClaudeModelStripsVersionSuffix() {
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("anthropic.claude-sonnet-4-5-v1:0"), "claude-sonnet-4-5")
    }

    func testNormalizeClaudeModelPassesThroughCleanIds() {
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("claude-fable-5"), "claude-fable-5")
        XCTAssertEqual(ClaudeCostScanner.normalizeModel("  claude-haiku-4-5 "), "claude-haiku-4-5")
    }

    // MARK: - Pricing lookup

    func testClaudePricingExactAndFamilyMatches() {
        XCTAssertEqual(ClaudeCostScanner.pricing(for: "claude-fable-5").input, 10.0)
        // Dated ids normalize onto the base id.
        XCTAssertEqual(ClaudeCostScanner.pricing(for: "claude-opus-4-8-20260101").input, 5.0)
        // Family fallback for unknown fable variants.
        XCTAssertEqual(ClaudeCostScanner.pricing(for: "claude-fable-9").input, 10.0)
        // Unknown models get the default (sonnet-rate) pricing.
        XCTAssertEqual(ClaudeCostScanner.pricing(for: "mystery-model").input, 3.0)
        XCTAssertEqual(ClaudeCostScanner.pricing(for: nil).input, 3.0)
    }

    // MARK: - Cost formula

    func testCalculateCostMatchesClaudeCostWithoutOneHourTier() {
        let pricing = TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)

        let simple = TokenCostMath.calculateCost(
            input: 1_000_000, output: 2_000_000, cacheCreation: 500_000, cacheRead: 4_000_000, pricing: pricing
        )
        let claude = TokenCostMath.calculateClaudeCost(
            input: 1_000_000, output: 2_000_000, cacheCreation: 500_000,
            cacheCreationOneHour: 0, cacheRead: 4_000_000, pricing: pricing
        )

        XCTAssertEqual(simple, claude, accuracy: 0.0001)
        // 3 + 30 + 1.875 + 1.2
        XCTAssertEqual(simple, 36.075, accuracy: 0.0001)
    }

    func testCalculateCostClampsNegativeInputs() {
        // Both variants share one formula now, so negative token counts clamp
        // to zero instead of producing negative dollars (previously only the
        // Claude variant clamped).
        let pricing = TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
        let cost = TokenCostMath.calculateCost(
            input: -500, output: -1, cacheCreation: -2, cacheRead: -3, pricing: pricing
        )
        XCTAssertEqual(cost, 0, accuracy: 0.0001)
    }

    func testOneHourCacheTierPricedSeparately() {
        let pricing = TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0)
        let cost = TokenCostMath.calculateClaudeCost(
            input: 0, output: 0,
            cacheCreation: 2_000_000, cacheCreationOneHour: 1_000_000,
            cacheRead: 0, pricing: pricing
        )
        // 1M at the 5-minute rate (6.25) + 1M at the 1-hour rate (10.0)
        XCTAssertEqual(cost, 16.25, accuracy: 0.0001)
    }

    // MARK: - Session-file parsing

    private func writeSessionFile(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostTrackerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }

    private func eventLine(
        timestamp: String,
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        model: String = "claude-sonnet-4-5",
        input: Int = 100,
        output: Int = 50
    ) -> String {
        let idPart = messageID.map { "\"id\": \"\($0)\"," } ?? ""
        let requestPart = requestID.map { "\"requestId\": \"\($0)\"," } ?? ""
        return """
        {"timestamp": "\(timestamp)", \(requestPart) "message": {\(idPart) "model": "\(model)", \
        "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    func testParseSessionFileDeduplicatesRetriedEvents() throws {
        // Same messageID:requestID twice = one billed event. (The old CLI
        // scanner double-counted these, which is why it disagreed with the app.)
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z"),
            eventLine(timestamp: "2026-07-01T10:00:05.000Z"),
            eventLine(timestamp: "2026-07-01T11:00:00.000Z", messageID: "msg_2", requestID: "req_2", input: 7, output: 3)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 107)
        XCTAssertEqual(result.output, 53)
    }

    func testParseSessionFileHonorsPerEventCutoff() throws {
        // Events older than the cutoff are excluded even when the FILE was
        // modified recently. (The old CLI scanner only checked file mtime.)
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", messageID: "old", requestID: "old"),
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "new", requestID: "new", input: 42, output: 8)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 42)
        XCTAssertEqual(result.output, 8)
    }

    func testParseSessionFileAppliesPerModelPricing() throws {
        // 1M input on sonnet pricing = $3.00 exactly.
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 1_000_000, output: 0)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.estimatedCost, 3.0, accuracy: 0.0001)
        XCTAssertEqual(Array(result.models.keys), ["claude-sonnet-4-5"])
    }

    func testParseSessionFileSkipsMalformedLines() throws {
        let url = try writeSessionFile(lines: [
            "not json at all",
            "{\"timestamp\": \"garbage\"}",
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 5, output: 5)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 5)
    }

    // MARK: - Oversized transcript lines

    /// A line past `FileLineReader.defaultMaxLineBytes` reaches the scanner as a
    /// bounded prefix rather than being dropped. Length alone must never
    /// suppress a record: this one's usage block survives inside the prefix, so
    /// its spend still counts.
    func testParseSessionFileCountsTruncatedRecordsWhoseUsageSurvived() throws {
        let padding = String(repeating: " ", count: FileLineReader.defaultPrefixBytes)
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 120, output: 30) + padding
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 120)
        XCTAssertEqual(result.output, 30)
    }

    /// The other half of the contract: a prefix that does not parse is skipped
    /// like any other malformed line, without stalling the rest of the file.
    /// Before the streaming cap this shape is what put a whole transcript's
    /// worth of spend at risk.
    func testParseSessionFileKeepsScanningPastAnOversizedUnparseableLine() throws {
        let blob = String(repeating: "x", count: FileLineReader.defaultMaxLineBytes + 2_048)
        let url = try writeSessionFile(lines: [
            "{\"timestamp\": \"2026-07-01T10:00:00.000Z\", \"toolUseResult\": \"\(blob)\"}",
            eventLine(timestamp: "2026-07-02T10:00:00.000Z", input: 5, output: 5)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 5)
        XCTAssertEqual(result.output, 5)
    }

    // MARK: - Project attribution (issue #270)

    func testParseSessionFileDefaultsUnattributedEventsToTheUnknownProjectBucket() throws {
        // No projectID argument supplied: every existing call site (and every
        // pre-#270 caller) must keep working exactly as before, landing in the
        // explicit "unknown" bucket rather than silently dropping the totals.
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 10, output: 5)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.projects[CostProjectAttribution.unknownProjectID]?.input, 10)
        XCTAssertEqual(result.projectModels[CostProjectAttribution.unknownProjectID]?["claude-sonnet-4-5"]?.input, 10)
    }

    func testParseSessionFileAttributesEventsToTheSuppliedProjectID() throws {
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 10, output: 5),
            eventLine(
                timestamp: "2026-07-01T11:00:00.000Z", messageID: "msg_2", requestID: "req_2",
                model: "claude-opus-4-5", input: 7, output: 3
            )
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff, projectID: "meterbardev")

        XCTAssertEqual(result.projects["meterbardev"]?.input, 17)
        XCTAssertEqual(result.projectModels["meterbardev"]?["claude-sonnet-4-5"]?.input, 10)
        XCTAssertEqual(result.projectModels["meterbardev"]?["claude-opus-4-5"]?.input, 7)
        // No stray "unknown" bucket once a real projectID is threaded through.
        XCTAssertNil(result.projects[CostProjectAttribution.unknownProjectID])

        let day = Calendar.current.startOfDay(
            for: try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-01T10:00:00.000Z"))
        )
        XCTAssertEqual(result.dailyModels[day]?["claude-sonnet-4-5"]?.input, 10)
        XCTAssertEqual(result.dailyModels[day]?["claude-opus-4-5"]?.input, 7)
        XCTAssertEqual(result.dailyProjects[day]?["meterbardev"]?.input, 17)
        XCTAssertEqual(
            result.dailyProjectModels[day]?["meterbardev"]?["claude-opus-4-5"]?.input,
            7
        )

        let (_, dailyRows) = try XCTUnwrap(
            ClaudeCostScanner.makeCost(from: result, windowStart: cutoff)
        )
        let daily = try XCTUnwrap(dailyRows.first)
        XCTAssertEqual(daily.modelBreakdowns?.count, 2)
        XCTAssertEqual(daily.projectBreakdowns?.first?.name, "meterbardev")
        XCTAssertEqual(daily.projectBreakdowns?.first?.modelBreakdowns.count, 2)
    }

    func testParseSessionWindowsAppliesTheSameProjectIDToBothWindows() throws {
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", messageID: "old", requestID: "old", input: 4, output: 1),
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "new", requestID: "new", input: 10, output: 5)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff, projectID: "meterbardev")

        XCTAssertEqual(windows.period.projects["meterbardev"]?.input, 10)
        XCTAssertEqual(windows.lifetime.projects["meterbardev"]?.input, 14)
    }

    func testScanSessionsDerivesProjectIDFromTheEncodedSessionDirectory() throws {
        // Mirrors how Claude Code actually lays transcripts out on disk:
        // <configDir>/projects/<encoded-cwd>/session.jsonl.
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostTrackerTests-account-\(UUID().uuidString)", isDirectory: true)
        let home = ServiceSupport.realHomeDirectory()
        let encodedHome = "-" + home.split(separator: "/").joined(separator: "-")
        let encodedProjectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("\(encodedHome)-www-demo-project", isDirectory: true)
        try FileManager.default.createDirectory(at: encodedProjectDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }

        let sessionURL = encodedProjectDir.appendingPathComponent("session.jsonl")
        try eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 10, output: 5)
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let account = ClaudeCodeAccount(id: UUID(), name: "demo", configDirectory: configDir.path)
        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)
        let windows = ClaudeCostScanner.scanRoots(
            ClaudeCostScanner.projectRoots(accounts: [account]),
            session: session
        )

        XCTAssertEqual(windows.period.projects["www/demo/project"]?.input, 10)
    }

    // MARK: - Codex rollout scan

    /// Writes a `.jsonl` into an `archived_sessions` directory and returns that
    /// directory (the argument `CostScanFixtureScan.codexRollouts` expects). Every file is
    /// read regardless of its modification date, so the lifetime window sees
    /// pre-cutoff lines too.
    private func writeCodexArchive(lines: [String]) throws -> URL {
        let root = try makeCodexHome()
        let dir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return dir
    }

    /// Temp stand-in for `~/.codex`, cleaned up after the test.
    private func makeCodexHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Writes a rollout at an arbitrary path under a Codex home, creating the
    /// intermediate `sessions/YYYY/MM/DD` folders Codex nests live rollouts in.
    ///
    /// The trailing newline is not decoration: the budgeted scan withholds an
    /// unterminated last line, so a fixture without one loses its final event.
    @discardableResult
    private func writeCodexRollout(
        in root: URL,
        path: String,
        modifiedAgo: TimeInterval? = nil,
        lines: [String]
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAgo {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_780_000_000 - modifiedAgo)],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    /// Real rollouts open with a `session_meta` event; the model field there is
    /// always null in practice, but the originator identifies the front end.
    private func codexSessionMetaLine(timestamp: String, originator: String = "Codex Desktop") -> String {
        """
        {"timestamp": "\(timestamp)", "type": "session_meta", "payload": \
        {"id": "conv-1", "originator": "\(originator)", "cli_version": "0.0.0"}}
        """
    }

    /// The only place a real rollout records which model is answering.
    private func codexTurnContextLine(timestamp: String, model: String) -> String {
        """
        {"timestamp": "\(timestamp)", "type": "turn_context", "payload": \
        {"model": "\(model)", "effort": "high", "summary": "auto"}}
        """
    }

    /// A realistic `token_count` event: no model anywhere on the event itself.
    private func codexUsageLine(
        timestamp: String,
        conversationID: String = "conv-1",
        input: Int = 1_000,
        output: Int = 500,
        cached: Int = 200,
        reasoning: Int = 50
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "type": "event_msg", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": \(cached), "reasoning_output_tokens": \(reasoning)}}}}
        """
    }

    private func codexTokenLine(
        timestamp: String,
        conversationID: String = "conv-1",
        model: String = "gpt-5.5",
        input: Int = 1_000,
        output: Int = 500,
        cached: Int = 200,
        reasoning: Int = 50
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"model": "\(model)", "last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": \(cached), "reasoning_output_tokens": \(reasoning)}}}}
        """
    }

    private func makeContext(cutoff: Date) -> CodexScanContext {
        CodexScanContext(earliestDate: Date(), latestDate: cutoff)
    }

    func testScanCodexRolloutsAccumulatesTokenCounts() throws {
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 1_000)
        // output accumulates the reasoning tokens on the daily/model rollups, but
        // `totals` keeps output and reasoning separate.
        XCTAssertEqual(context.totals.output, 500)
        XCTAssertEqual(context.totals.reasoning, 50)
        XCTAssertEqual(context.totals.cacheRead, 200)
        XCTAssertEqual(context.sessionIDs, ["conv-1"])
    }

    func testScanCodexRolloutsDeduplicatesIdenticalEvents() throws {
        let line = codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        let dir = try writeCodexArchive(lines: [line, line])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        // Identical events collapse to one via the dedup key.
        XCTAssertEqual(context.totals.input, 1_000)
        XCTAssertEqual(context.totals.output, 500)
    }

    func testScanCodexRolloutsHonorsPerLineCutoff() throws {
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2025-01-01T00:00:00Z", conversationID: "old", input: 9_999),
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z", conversationID: "new", input: 100)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        // Only the post-cutoff line is counted.
        XCTAssertEqual(context.totals.input, 100)
        XCTAssertEqual(context.sessionIDs, ["new"])
    }

    /// Rollouts in `~/.codex/sessions` reach 56 MB on a single line. The reader
    /// keeps a bounded prefix of one instead of dropping it, and `token_count`
    /// sits near the front of the record — so the tokens still land. Dropping
    /// the line would silently under-report the session's spend.
    func testScanCodexRolloutsCountsTruncatedTokenCountLines() throws {
        let padding = String(repeating: " ", count: FileLineReader.defaultPrefixBytes)
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z") + padding
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 1_000)
        XCTAssertEqual(context.totals.output, 500)
        XCTAssertEqual(context.sessionIDs, ["conv-1"])
    }

    /// An oversized line the prefix cannot explain is skipped, but the rollout
    /// keeps streaming: the usage recorded after it is still counted.
    func testScanCodexRolloutsKeepsScanningPastAnOversizedUnparseableLine() throws {
        let blob = String(repeating: "x", count: FileLineReader.defaultMaxLineBytes + 2_048)
        let oversized = """
        {"timestamp": "2026-06-15T09:00:00Z", "type": "response_item", "payload": \
        {"type": "message", "content": "\(blob)"}}
        """
        let dir = try writeCodexArchive(lines: [
            oversized,
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z", input: 42, output: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 42)
        XCTAssertEqual(context.totals.output, 7)
    }

    // MARK: - Codex model + origin attribution

    func testScanCodexRolloutsAttributesTurnContextModelAndSessionOriginator() throws {
        // Real `token_count` events carry no model, so the whole Codex spend used
        // to land under "Unknown model"/"Codex CLI". The model lives on the
        // preceding `turn_context`, the front end on the opening `session_meta`.
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLine(timestamp: "2026-06-15T09:59:00Z", originator: "Codex Desktop"),
            codexTurnContextLine(timestamp: "2026-06-15T09:59:30Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(Array(context.modelTotals.keys), ["gpt-5.6-sol"])
        XCTAssertEqual(Array(context.originTotals.keys), ["Codex Desktop"])
        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 1_000)
    }

    // MARK: - Codex project attribution (issue #270)

    /// `session_meta.payload.cwd` is the real, unencoded working directory —
    /// legitimate non-prompt-content field, distinct from anything the user
    /// typed. It's read once per file, same as Claude's directory-derived ID.
    private func codexSessionMetaLineWithCwd(timestamp: String, cwd: String) -> String {
        """
        {"timestamp": "\(timestamp)", "type": "session_meta", "payload": \
        {"id": "conv-1", "originator": "Codex CLI", "cwd": "\(cwd)", "cli_version": "0.0.0"}}
        """
    }

    func testScanCodexRolloutsAttributesUsageToTheSessionMetaCwd() throws {
        let home = ServiceSupport.realHomeDirectory()
        let cwd = "\(home)/www/genfeed/apps/admin"
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLineWithCwd(timestamp: "2026-06-15T09:59:00Z", cwd: cwd),
            codexUsageLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.projectTotals["www/genfeed/apps/admin"]?.input, 1_000)
        XCTAssertNil(context.projectTotals[CostProjectAttribution.unknownProjectID])
    }

    func testScanCodexRolloutsFallBackToUnknownProjectWithoutSessionMetaCwd() throws {
        // No session_meta at all: nothing to derive a project from.
        let dir = try writeCodexArchive(lines: [
            codexUsageLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.projectTotals[CostProjectAttribution.unknownProjectID]?.input, 1_000)
    }

    func testScanCodexRolloutsNestsPerProjectModelBreakdown() throws {
        let home = ServiceSupport.realHomeDirectory()
        let cwd = "\(home)/www/genfeed/apps/admin"
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLineWithCwd(timestamp: "2026-06-15T09:59:00Z", cwd: cwd),
            codexTurnContextLine(timestamp: "2026-06-15T09:59:30Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.projectModelTotals["www/genfeed/apps/admin"]?["gpt-5.6-sol"]?.input, 1_000)

        let day = Calendar.current.startOfDay(
            for: try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T10:00:00Z"))
        )
        XCTAssertEqual(context.dailyModelTotals[day]?["gpt-5.6-sol"]?.input, 1_000)
        XCTAssertEqual(context.dailyProjectTotals[day]?["www/genfeed/apps/admin"]?.input, 1_000)
        XCTAssertEqual(
            context.dailyProjectModelTotals[day]?["www/genfeed/apps/admin"]?["gpt-5.6-sol"]?.input,
            1_000
        )

        let (_, dailyRows) = try XCTUnwrap(CodexCostScanner.makeCost(from: context))
        let daily = try XCTUnwrap(dailyRows.first)
        XCTAssertEqual(daily.modelBreakdowns?.first?.name, "gpt-5.6-sol")
        XCTAssertEqual(daily.projectBreakdowns?.first?.name, "www/genfeed/apps/admin")
        XCTAssertEqual(daily.projectBreakdowns?.first?.modelBreakdowns.first?.name, "gpt-5.6-sol")
    }

    // Note: `scanSQLiteLogs` (the flat SQLite log format) is `private` with no
    // existing fixture-injection seam — it always reads the real Codex home's
    // `logs_2.sqlite` via `scanSessions`. That format carries no cwd/path field
    // at all, so its call site passes `CostProjectAttribution.unknownProjectID`
    // directly (verified by code inspection in `CodexCostScanner.swift`); the
    // "unknown" bucket behavior itself is exercised above via the rollout path,
    // which shares the same `addUsage` attribution logic.

    func testScanCodexRolloutsFollowsMidSessionModelSwitch() throws {
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLine(timestamp: "2026-06-15T09:00:00Z"),
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", input: 100),
            codexTurnContextLine(timestamp: "2026-06-15T09:03:00Z", model: "gpt-5.6-luna"),
            codexUsageLine(timestamp: "2026-06-15T09:04:00Z", input: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 100)
        XCTAssertEqual(context.modelTotals["gpt-5.6-luna"]?.input, 7)
    }

    func testScanCodexRolloutsKeepsUnknownLabelsWithoutContextEvents() throws {
        // A truncated rollout with no session_meta/turn_context still counts its
        // tokens; it just can't name the model or the front end.
        let dir = try writeCodexArchive(lines: [
            codexUsageLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(Array(context.modelTotals.keys), ["Unknown model"])
        XCTAssertEqual(Array(context.originTotals.keys), ["Codex CLI"])
    }

    func testScanCodexRolloutsPrefersEventModelOverTurnContext() throws {
        // Older rollouts stamped the model onto the event itself; when both are
        // present the event wins because it is the more specific record.
        let dir = try writeCodexArchive(lines: [
            codexTurnContextLine(timestamp: "2026-06-15T09:59:30Z", model: "gpt-5.6-sol"),
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z", model: "gpt-5.5")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(Array(context.modelTotals.keys), ["gpt-5.5"])
    }

    func testScanCodexRolloutsResetsAttributionBetweenFiles() throws {
        // Streaming state is per file: one rollout's model must not leak into a
        // sibling that never declares one.
        let root = try makeCodexHome()
        let dir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try writeCodexRollout(in: dir, path: "a.jsonl", lines: [
            codexSessionMetaLine(timestamp: "2026-06-15T09:00:00Z", originator: "Codex Desktop"),
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-a", input: 100)
        ])
        try writeCodexRollout(in: dir, path: "b.jsonl", lines: [
            codexUsageLine(timestamp: "2026-06-15T09:05:00Z", conversationID: "conv-b", input: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 100)
        XCTAssertEqual(context.modelTotals["Unknown model"]?.input, 7)
        XCTAssertEqual(context.originTotals["Codex Desktop"]?.input, 100)
        XCTAssertEqual(context.originTotals["Codex CLI"]?.input, 7)
    }

    /// Codex emits the first `token_count` events of a session *before* the
    /// first `turn_context`, so forward-only attribution orphaned them even
    /// though the same file names the model seconds later. Measured against the
    /// 400 most recent live rollouts, that was 100% of the "Unknown model" row.
    func testScanCodexRolloutsBackfillsUsageEmittedBeforeTheFirstTurnContext() throws {
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLine(timestamp: "2026-06-15T09:00:00Z"),
            codexUsageLine(timestamp: "2026-06-15T09:00:30Z", input: 100),
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", input: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 107)
        XCTAssertNil(context.modelTotals["Unknown model"], "the file names the model — nothing is unknown")
    }

    /// Back-fill reaches backwards only as far as the *first* model the file
    /// declares. A later switch must not relabel the events that preceded it.
    func testScanCodexRolloutsBackfillStopsAtTheFirstModel() throws {
        let dir = try writeCodexArchive(lines: [
            codexSessionMetaLine(timestamp: "2026-06-15T09:00:00Z"),
            codexUsageLine(timestamp: "2026-06-15T09:00:30Z", input: 100),
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", input: 7),
            codexTurnContextLine(timestamp: "2026-06-15T09:03:00Z", model: "gpt-5.6-luna"),
            codexUsageLine(timestamp: "2026-06-15T09:04:00Z", input: 3)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 107)
        XCTAssertEqual(context.modelTotals["gpt-5.6-luna"]?.input, 3)
    }

    /// The pending buffer is per file, like the rollout context itself: a
    /// sibling's model must not name events the truncated file never explained.
    func testScanCodexRolloutsDoesNotBackfillAcrossFiles() throws {
        let root = try makeCodexHome()
        let dir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try writeCodexRollout(in: dir, path: "a.jsonl", lines: [
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-a", input: 100)
        ])
        try writeCodexRollout(in: dir, path: "b.jsonl", lines: [
            codexTurnContextLine(timestamp: "2026-06-15T09:04:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:05:00Z", conversationID: "conv-b", input: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["Unknown model"]?.input, 100)
        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 7)
    }

    /// Back-filled events keep their own timestamps, so the daily rollups the
    /// charts read must land on each event's day rather than the flush's.
    func testScanCodexRolloutsBackfillKeepsPerEventDayPlacement() throws {
        let dir = try writeCodexArchive(lines: [
            codexUsageLine(timestamp: "2026-06-14T12:00:00Z", input: 100),
            codexTurnContextLine(timestamp: "2026-06-16T11:00:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-16T12:00:00Z", input: 7)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        let firstDay = Calendar.current.startOfDay(
            for: try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-14T12:00:00Z"))
        )
        let secondDay = Calendar.current.startOfDay(
            for: try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-16T12:00:00Z"))
        )
        XCTAssertNotEqual(firstDay, secondDay)
        XCTAssertEqual(context.dailyModelTotals[firstDay]?["gpt-5.6-sol"]?.input, 100)
        XCTAssertEqual(context.dailyModelTotals[secondDay]?["gpt-5.6-sol"]?.input, 7)
    }

    // MARK: - Codex rollout directories

    func testCodexRolloutDirectoriesCoverArchivedAndLiveSessions() {
        let home = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)

        let names = CodexCostScanner.rolloutDirectories(in: home).map(\.lastPathComponent)

        // Live rollouts land in `sessions/`; only closed ones get archived, so
        // scanning `archived_sessions` alone understated recent days.
        XCTAssertEqual(names, ["archived_sessions", "sessions"])
    }

    func testScanCodexRolloutsWalksNestedSessionDirectories() throws {
        let root = try makeCodexHome()
        let dir = root.appendingPathComponent("sessions", isDirectory: true)
        try writeCodexRollout(in: dir, path: "2026/06/15/rollout-conv-x.jsonl", lines: [
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 100)
        XCTAssertEqual(context.sessionIDs, ["conv-x"])
    }

    func testScanCodexRolloutsDeduplicatesAcrossDirectories() throws {
        // A rollout copied from `sessions/` into `archived_sessions` on close
        // must not double-count once both directories are scanned.
        let root = try makeCodexHome()
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let live = root.appendingPathComponent("sessions", isDirectory: true)
        let lines = [
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        ]
        try writeCodexRollout(in: archived, path: "rollout-conv-x.jsonl", lines: lines)
        try writeCodexRollout(in: live, path: "2026/06/15/rollout-conv-x.jsonl", lines: lines)
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        for directory in CodexCostScanner.rolloutDirectories(in: root) {
            CostScanFixtureScan.codexRollouts(in: directory, since: cutoff, context: &context)
        }

        XCTAssertEqual(context.totals.input, 100)
        XCTAssertEqual(context.modelTotals["gpt-5.6-sol"]?.input, 100)
    }

    // MARK: - Budgeted Codex rollout scan

    /// Names a rollout the way Codex does: the session UUID trails an ISO
    /// timestamp, and the archived copy keeps the whole name.
    private func codexRolloutName(sessionID: UUID, stamp: String = "2026-06-15T09-00-00") -> String {
        "rollout-\(stamp)-\(sessionID.uuidString.lowercased()).jsonl"
    }

    func testRolloutSessionIDIdentifiesTheArchivedCopyOfALiveRollout() {
        let id = UUID()
        let live = URL(fileURLWithPath: "/codex/sessions/2026/06/15/\(codexRolloutName(sessionID: id))")
        let archived = URL(fileURLWithPath: "/codex/archived_sessions/\(codexRolloutName(sessionID: id))")

        XCTAssertEqual(
            CodexCostScanner.rolloutSessionID(for: live),
            CodexCostScanner.rolloutSessionID(for: archived)
        )
        XCTAssertEqual(CodexCostScanner.rolloutSessionID(for: live), id.uuidString.lowercased())
    }

    func testRolloutSessionIDFallsBackToTheWholeStemWithoutAUUIDSuffix() {
        let legacy = URL(fileURLWithPath: "/codex/archived_sessions/rollout-conv-x.jsonl")

        XCTAssertEqual(CodexCostScanner.rolloutSessionID(for: legacy), "rollout-conv-x")
    }

    /// The duplicate the fold fallback exists for. Reading only one copy is what
    /// keeps the fallback — and its unbudgeted re-parse — off the hot path
    /// entirely.
    func testBudgetedCodexScanReadsOnlyOneCopyOfADuplicatedRollout() throws {
        let root = try makeCodexHome()
        let name = codexRolloutName(sessionID: UUID())
        let lines = [
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        ]
        try writeCodexRollout(in: root, path: "archived_sessions/\(name)", modifiedAgo: 60, lines: lines)
        let live = try writeCodexRollout(
            in: root, path: "sessions/2026/06/15/\(name)", modifiedAgo: 0, lines: lines
        )
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-01-01T00:00:00Z"))
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)

        let windows = CodexCostScanner.scanRollouts(
            directories: CodexCostScanner.rolloutDirectories(in: root), session: session
        )

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(windows.period.totals.input, 100)
        // The copy still being appended to is the one worth caching an offset
        // against.
        XCTAssertEqual(Set(session.codex.records.keys), [live.standardizedFileURL.path])
    }

    /// A live rollout keeps growing after it is archived, so the longer copy is
    /// the one that carries every event.
    func testBudgetedCodexScanKeepsTheLongerCopyOfADuplicatedRollout() throws {
        let root = try makeCodexHome()
        let name = codexRolloutName(sessionID: UUID())
        let shared = [
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        ]
        try writeCodexRollout(in: root, path: "archived_sessions/\(name)", modifiedAgo: 60, lines: shared)
        try writeCodexRollout(
            in: root,
            path: "sessions/2026/06/15/\(name)",
            modifiedAgo: 0,
            lines: shared + [
                codexUsageLine(timestamp: "2026-06-15T09:03:00Z", conversationID: "conv-x", input: 25)
            ]
        )
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-01-01T00:00:00Z"))
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)

        let windows = CodexCostScanner.scanRollouts(
            directories: CodexCostScanner.rolloutDirectories(in: root), session: session
        )

        XCTAssertEqual(windows.period.totals.input, 125)
        XCTAssertEqual(session.codex.records.count, 1)
    }

    /// Deduplication picks one copy per session; it must not also decide the
    /// reading order. `archived_sessions` is enumerated first, so returning
    /// discovery order would put every archived rollout ahead of every live one
    /// and spend a slice's whole budget on the oldest conversations on disk —
    /// the exact inversion of the newest-first walk the budget assumes.
    func testDistinctRolloutsOrdersNewestFirstAcrossDirectories() throws {
        let root = try makeCodexHome()
        let lines = [
            codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol"),
            codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        ]
        let old = try writeCodexRollout(
            in: root,
            path: "archived_sessions/\(codexRolloutName(sessionID: UUID()))",
            modifiedAgo: 6000,
            lines: lines
        )
        let recent = try writeCodexRollout(
            in: root,
            path: "sessions/2026/06/15/\(codexRolloutName(sessionID: UUID()))",
            modifiedAgo: 60,
            lines: lines
        )

        let files = CodexCostScanner.distinctRollouts(
            in: CodexCostScanner.rolloutDirectories(in: root)
        )

        XCTAssertEqual(
            files.map(\.url.standardizedFileURL.path),
            [recent.standardizedFileURL.path, old.standardizedFileURL.path]
        )
    }

    /// Two rollouts that are not copies of one session but still share events.
    /// Aggregates cannot be de-overlapped, so the shorter one is re-read event
    /// by event — and that read has to answer to the same budget as every other.
    func testCodexFoldFallbackCountsTheOverlappingRolloutOnce() throws {
        let root = try makeCodexHome()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-01-01T00:00:00Z"))
        try writeOverlappingCodexRollouts(in: root)
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)

        let windows = CodexCostScanner.scanRollouts(
            directories: CodexCostScanner.rolloutDirectories(in: root), session: session
        )

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(windows.period.totals.input, 150)
    }

    func testCodexFoldFallbackDefersRatherThanReadingPastTheBudget() throws {
        let root = try makeCodexHome()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-01-01T00:00:00Z"))
        let sizes = try writeOverlappingCodexRollouts(in: root)
        // Exactly enough to read both files once. The fallback re-read of the
        // second one has to come out of a budget that is already spent.
        let budget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: sizes.reduce(0, +),
            wallClock: nil
        )
        let session = CostScanSession(cutoff: cutoff, options: budget)

        let windows = CodexCostScanner.scanRollouts(
            directories: CodexCostScanner.rolloutDirectories(in: root), session: session
        )

        // 150 would mean the fallback read the overlapping rollout anyway.
        XCTAssertEqual(windows.period.totals.input, 100)
        XCTAssertFalse(session.isComplete)
    }

    /// Two distinct sessions whose events overlap: the newer file holds one
    /// event, the older holds that same event plus one more. Returns each file's
    /// size in scan order.
    @discardableResult
    private func writeOverlappingCodexRollouts(in root: URL) throws -> [Int] {
        let shared = codexUsageLine(timestamp: "2026-06-15T09:02:00Z", conversationID: "conv-x", input: 100)
        let context = codexTurnContextLine(timestamp: "2026-06-15T09:01:00Z", model: "gpt-5.6-sol")
        let newer = try writeCodexRollout(
            in: root,
            path: "sessions/2026/06/15/\(codexRolloutName(sessionID: UUID()))",
            modifiedAgo: 0,
            lines: [context, shared]
        )
        let older = try writeCodexRollout(
            in: root,
            path: "sessions/2026/06/15/\(codexRolloutName(sessionID: UUID(), stamp: "2026-06-15T08-00-00"))",
            modifiedAgo: 60,
            lines: [
                context,
                shared,
                codexUsageLine(timestamp: "2026-06-15T09:05:00Z", conversationID: "conv-x", input: 50)
            ]
        )
        return try [newer, older].map { try fileSize($0) }
    }

    // MARK: - Period/lifetime windows (single-pass scan)

    func testParseSessionWindowsSplitsPeriodFromLifetime() throws {
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", messageID: "old", requestID: "old",
                      input: 10, output: 1),
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "new", requestID: "new",
                      input: 42, output: 8)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 42)
        XCTAssertEqual(windows.period.output, 8)
        XCTAssertEqual(windows.lifetime.input, 52)
        XCTAssertEqual(windows.lifetime.output, 9)
        XCTAssertEqual(windows.period.sessions, 1)
        XCTAssertEqual(windows.lifetime.sessions, 1)
    }

    func testParseSessionWindowsMatchesTwoSeparateScans() throws {
        // The whole point of the single-pass rewrite: one traversal must produce
        // exactly what two independently-cutoff traversals used to produce.
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", messageID: "a", requestID: "a",
                      input: 1_000_000, output: 0),
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "b", requestID: "b",
                      input: 1_000_000, output: 0)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)
        let period = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)
        let lifetime = ClaudeCostScanner.parseSessionFile(at: url, since: .distantPast)

        XCTAssertEqual(windows.period.input, period.input)
        XCTAssertEqual(windows.period.estimatedCost, period.estimatedCost, accuracy: 0.0001)
        XCTAssertEqual(windows.lifetime.input, lifetime.input)
        XCTAssertEqual(windows.lifetime.estimatedCost, lifetime.estimatedCost, accuracy: 0.0001)
        // period ⊆ lifetime is structural, not incidental.
        XCTAssertEqual(windows.lifetime.input, 2_000_000)
        XCTAssertEqual(windows.period.input, 1_000_000)
    }

    func testParseSessionWindowsDeduplicatesWithinEachWindow() throws {
        // A retried event whose duplicate straddles the cutoff. Deduplicating
        // once across the whole file and filtering afterwards would let the
        // pre-cutoff copy win and change the period total, so each window keeps
        // its own dedup map.
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 100, output: 50),
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", input: 7, output: 3)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        // Period only ever saw the in-window copy.
        XCTAssertEqual(windows.period.input, 100)
        XCTAssertEqual(windows.period.output, 50)
        // Lifetime saw both copies as one event; last line in the file wins,
        // matching what a `.distantPast` scan produces today.
        XCTAssertEqual(windows.lifetime.input, 7)
        XCTAssertEqual(windows.lifetime.output, 3)
    }

    func testParseSessionWindowsTracksEarliestAndLatestPerWindow() throws {
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-05-01T10:00:00.000Z", messageID: "old", requestID: "old"),
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "new", requestID: "new")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.earliest, FlexibleISO8601.date(from: "2026-07-01T10:00:00.000Z"))
        XCTAssertEqual(windows.lifetime.earliest, FlexibleISO8601.date(from: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(windows.lifetime.latest, FlexibleISO8601.date(from: "2026-07-01T10:00:00.000Z"))
    }

    /// Mirrors the key order of a real Claude transcript record: `content` sits
    /// ahead of `usage` inside `message`, and the top-level `timestamp` trails
    /// the whole message object. Both fields a usage event needs are therefore
    /// past the prefix cut once `content` is large. Nothing pads the line after
    /// its closing brace — padding is what made the older truncation fixtures
    /// salvageable by accident.
    private func oversizedEventLine(
        timestamp: String,
        contentBytes: Int,
        messageID: String = "msg_big",
        requestID: String = "req_big",
        model: String = "claude-sonnet-4-5",
        input: Int = 100,
        output: Int = 50
    ) -> String {
        let blob = String(repeating: "a", count: contentBytes)
        return """
        {"parentUuid": "p-1", "isSidechain": false, "message": {"model": "\(model)", "id": "\(messageID)", \
        "type": "message", "role": "assistant", "content": [{"type": "text", "text": "\(blob)"}], \
        "stop_reason": "end_turn", "stop_sequence": null, \
        "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}, \
        "requestId": "\(requestID)", "type": "assistant", "uuid": "u-1", "timestamp": "\(timestamp)"}
        """
    }

    func testParseSessionWindowsCountsUsageStrandedPastTheTruncationCap() throws {
        let url = try writeSessionFile(lines: [
            oversizedEventLine(
                timestamp: "2026-07-01T10:00:00.000Z",
                contentBytes: FileLineReader.defaultMaxLineBytes + 4_096,
                input: 900,
                output: 90
            ),
            eventLine(
                timestamp: "2026-07-01T11:00:00.000Z",
                messageID: "small",
                requestID: "small",
                input: 100,
                output: 10
            )
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 1_000)
        XCTAssertEqual(windows.period.output, 100)
        XCTAssertEqual(windows.lifetime.input, 1_000)
        XCTAssertEqual(windows.period.models["claude-sonnet-4-5"]?.input, 1_000)
    }

    func testSalvagedUsageIsDeduplicatedAgainstItsUntruncatedCopy() throws {
        // A retried record can land once small and once oversized. The salvage
        // path has to recover the same `messageID:requestID` key, or the spend
        // is counted twice.
        let url = try writeSessionFile(lines: [
            eventLine(
                timestamp: "2026-07-01T10:00:00.000Z",
                messageID: "msg_big",
                requestID: "req_big",
                input: 900,
                output: 90
            ),
            oversizedEventLine(
                timestamp: "2026-07-01T10:00:01.000Z",
                contentBytes: FileLineReader.defaultMaxLineBytes + 4_096,
                input: 900,
                output: 90
            )
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 900)
        XCTAssertEqual(windows.period.output, 90)
    }

    func testTruncatedLineWithNoRecoverableUsageIsSkippedWithoutDisturbingTheScan() throws {
        let blob = String(repeating: "a", count: FileLineReader.defaultMaxLineBytes + 4_096)
        let url = try writeSessionFile(lines: [
            #"{"type": "user", "message": {"role": "user", "content": "\#(blob)"}}"#,
            eventLine(
                timestamp: "2026-07-01T11:00:00.000Z",
                messageID: "after",
                requestID: "after",
                input: 12,
                output: 3
            )
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 12)
        XCTAssertEqual(windows.period.output, 3)
    }

    func testBudgetedScanCountsUsageStrandedPastTheTruncationCap() throws {
        let root = try makeTranscriptRoot()
        try writeTranscript(in: root, name: "session.jsonl", modifiedAgo: 0, lines: [
            oversizedEventLine(
                timestamp: "2026-07-01T10:00:00.000Z",
                contentBytes: FileLineReader.defaultMaxLineBytes + 4_096,
                input: 900,
                output: 90
            )
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)

        let windows = ClaudeCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(windows.period.input, 900)
        XCTAssertEqual(windows.period.output, 90)
    }

    func testScanCodexRolloutWindowsSplitPeriodFromLifetime() throws {
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2025-01-01T00:00:00Z", conversationID: "old", input: 9_000),
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z", conversationID: "new", input: 100)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, windows: &windows)

        XCTAssertEqual(windows.period.totals.input, 100)
        XCTAssertEqual(windows.period.sessionIDs, ["new"])
        XCTAssertEqual(windows.lifetime.totals.input, 9_100)
        XCTAssertEqual(windows.lifetime.sessionIDs, ["new", "old"])
    }

    func testScanCodexRolloutWindowsDeduplicateIndependently() throws {
        let line = codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        let dir = try writeCodexArchive(lines: [line, line])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)

        CostScanFixtureScan.codexRollouts(in: dir, windows: &windows)

        XCTAssertEqual(windows.period.totals.input, 1_000)
        XCTAssertEqual(windows.lifetime.totals.input, 1_000)
    }

    // MARK: - Budgeted, resumable corpus scan

    func testByteBudgetSmallerThanTheCorpusDefersTheRestWithoutLosingData() throws {
        let root = try makeTranscriptRoot()
        let newest = try writeTranscript(in: root, name: "newest.jsonl", modifiedAgo: 0, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 100, output: 10)
        ])
        let older = try writeTranscript(in: root, name: "older.jsonl", modifiedAgo: 3_600, lines: [
            eventLine(timestamp: "2026-07-02T10:00:00.000Z", messageID: "b", requestID: "b", input: 7, output: 3)
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()
        let budget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: try fileSize(newest),
            wallClock: nil
        )

        let first = CostScanSession(cutoff: cutoff, options: budget, store: store)
        let firstWindows = ClaudeCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist(), .persisted)

        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(firstWindows.period.input, 100)
        XCTAssertEqual(firstWindows.period.sessions, 1)
        XCTAssertNil(first.claude.records[older.standardizedFileURL.path])

        // A fresh refresh gets a fresh budget and picks up exactly what was left.
        let second = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        let secondWindows = ClaudeCostScanner.scanRoots([root], session: second)
        XCTAssertEqual(second.persist(), .persisted)

        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(secondWindows.period.input, 107)
        XCTAssertEqual(secondWindows.period.output, 13)
        XCTAssertEqual(secondWindows.period.sessions, 2)
    }

    func testSecondRefreshResumesFromThePersistedOffsetAndReadsOnlyAppendedBytes() throws {
        let root = try makeTranscriptRoot()
        let url = try writeTranscript(in: root, name: "session.jsonl", modifiedAgo: 0, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 100, output: 10)
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()

        let first = CostScanSession(cutoff: cutoff, options: .default, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist(), .persisted)

        let firstSize = try fileSize(url)
        XCTAssertEqual(first.budget.bytesRead, firstSize)
        XCTAssertEqual(first.claude.records[url.standardizedFileURL.path]?.offset, UInt64(firstSize))

        let appended = eventLine(
            timestamp: "2026-07-02T10:00:00.000Z", messageID: "b", requestID: "b", input: 7, output: 3
        ) + "\n"
        try append(appended, to: url)

        let second = CostScanSession(cutoff: cutoff, options: .default, store: store)
        let windows = ClaudeCostScanner.scanRoots([root], session: second)
        XCTAssertEqual(second.persist(), .persisted)

        XCTAssertEqual(second.budget.bytesRead, appended.utf8.count)
        XCTAssertEqual(windows.period.input, 107)
    }

    func testAppendingBetweenScansCountsTheNewRecordsExactlyOnce() throws {
        let root = try makeTranscriptRoot()
        let url = try writeTranscript(in: root, name: "session.jsonl", modifiedAgo: 0, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 100, output: 10)
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()

        let first = CostScanSession(cutoff: cutoff, options: .default, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist(), .persisted)

        try append(eventLine(
            timestamp: "2026-07-02T10:00:00.000Z", messageID: "b", requestID: "b", input: 7, output: 3
        ) + "\n", to: url)

        let second = CostScanSession(cutoff: cutoff, options: .default, store: store)
        let incremental = ClaudeCostScanner.scanRoots([root], session: second)

        // A cold scan of the finished file is the reference: incremental reads
        // must land on exactly the same totals, not double the appended event.
        let cold = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(incremental.period.input, cold.period.input)
        XCTAssertEqual(incremental.period.output, cold.period.output)
        XCTAssertEqual(incremental.period.estimatedCost, cold.period.estimatedCost, accuracy: 0.000_001)
        XCTAssertEqual(incremental.period.sessions, 1)
        XCTAssertEqual(incremental.lifetime.input, cold.lifetime.input)
    }

    func testHalfWrittenTrailingLineIsNotCommittedUntilItIsComplete() throws {
        let root = try makeTranscriptRoot()
        let complete = eventLine(
            timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 100, output: 10
        )
        let tail = eventLine(
            timestamp: "2026-07-02T10:00:00.000Z", messageID: "b", requestID: "b", input: 7, output: 3
        )
        let url = root.appendingPathComponent("session.jsonl")
        let head = String(tail.prefix(20))
        try (complete + "\n" + head).write(to: url, atomically: true, encoding: .utf8)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()

        let first = CostScanSession(cutoff: cutoff, options: .default, store: store)
        let firstWindows = ClaudeCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist(), .persisted)

        XCTAssertEqual(firstWindows.period.input, 100)
        XCTAssertEqual(
            first.claude.records[url.standardizedFileURL.path]?.offset,
            UInt64((complete + "\n").utf8.count)
        )

        try append(String(tail.dropFirst(head.count)) + "\n", to: url)

        let second = CostScanSession(cutoff: cutoff, options: .default, store: store)
        let secondWindows = ClaudeCostScanner.scanRoots([root], session: second)

        XCTAssertEqual(secondWindows.period.input, 107)
        XCTAssertEqual(secondWindows.period.output, 13)
    }

    func testNewestTranscriptsAreScannedFirstWhenTheBudgetCoversOnlySome() throws {
        let root = try makeTranscriptRoot()
        let oldest = try writeTranscript(in: root, name: "oldest.jsonl", modifiedAgo: 7_200, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "c", requestID: "c", input: 1, output: 1)
        ])
        let middle = try writeTranscript(in: root, name: "middle.jsonl", modifiedAgo: 3_600, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "b", requestID: "b", input: 10, output: 1)
        ])
        let newest = try writeTranscript(in: root, name: "newest.jsonl", modifiedAgo: 0, lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 100, output: 1)
        ])
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let budget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: try fileSize(newest),
            wallClock: nil
        )

        let session = CostScanSession(cutoff: cutoff, options: budget)
        let windows = ClaudeCostScanner.scanRoots([root], session: session)

        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(windows.period.input, 100)
        XCTAssertNotNil(session.claude.records[newest.standardizedFileURL.path])
        XCTAssertNil(session.claude.records[middle.standardizedFileURL.path])
        XCTAssertNil(session.claude.records[oldest.standardizedFileURL.path])
    }

    func testCancellationMidScanLeavesPersistedOffsetsOnLineBoundaries() async throws {
        let root = try makeTranscriptRoot()
        let fileCount = 40
        let linesPerFile = 40
        for file in 0..<fileCount {
            try writeTranscript(
                in: root,
                name: "session-\(file).jsonl",
                modifiedAgo: TimeInterval(file),
                lines: (0..<linesPerFile).map { line in
                    eventLine(
                        timestamp: "2026-07-01T10:00:00.000Z",
                        messageID: "m-\(file)-\(line)",
                        requestID: "r-\(file)-\(line)",
                        input: 10,
                        output: 1
                    )
                }
            )
        }
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()

        let scan = Task {
            try await CostScanExecutor.run { token in
                let session = CostScanSession(cutoff: cutoff, options: .unlimited, store: store, token: token)
                _ = ClaudeCostScanner.scanRoots([root], session: session)
                _ = session.persist()
            }
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        scan.cancel()
        _ = try? await scan.value
        // The scan queue is serial, so this only returns once the cancelled work
        // has finished persisting whatever it managed to read.
        _ = try await CostScanExecutor.run { _ in true }

        for (path, record) in store.loadClaude().records {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertLessThanOrEqual(Int(record.offset), bytes.count, path)
            if record.offset > 0 {
                XCTAssertEqual(bytes[Int(record.offset) - 1], UInt8(ascii: "\n"), path)
            }
        }

        let resumed = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        let windows = ClaudeCostScanner.scanRoots([root], session: resumed)

        XCTAssertTrue(resumed.isComplete)
        XCTAssertEqual(windows.period.input, fileCount * linesPerFile * 10)
        XCTAssertEqual(windows.period.output, fileCount * linesPerFile)
        XCTAssertEqual(windows.period.sessions, fileCount)
    }

    // MARK: - Applying a slice's result

    /// Demo mode is the vehicle rather than the subject: it stubs out the cache
    /// write, so these assert the publish/stamp decision without touching the
    /// real `~/Library/Application Support` summary.
    @MainActor
    private func makeApplyTracker(lastScan: Date) -> CostTracker {
        let tracker = CostTracker(demoMode: true)
        tracker.lastScanDate = lastScan
        return tracker
    }

    @MainActor
    func testIncompleteScanPublishesItsPartialTotalWithoutStampingTheScanClock() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let tracker = makeApplyTracker(lastScan: previous)
        let partial = CostSummary(
            costs: [],
            totalCostUSD: 4,
            totalTokens: 40,
            periodDays: 30,
            dailyUsage: [],
            lifetime: nil
        )

        tracker.apply(CostSummaryBuilder.CostSummaryScan(summary: partial, deferredProviders: [.claude]))

        // The number on screen improves with every slice...
        XCTAssertEqual(tracker.costSummary?.totalCostUSD, 4)
        // ...but an undercount must not be recorded as a finished scan: a
        // `lastScanDate` of today suppresses the background backfill for the
        // rest of the calendar day.
        XCTAssertEqual(tracker.lastScanDate, previous)
    }

    @MainActor
    func testCompleteScanStampsTheScanClock() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let tracker = makeApplyTracker(lastScan: previous)
        let whole = CostSummary(
            costs: [],
            totalCostUSD: 9,
            totalTokens: 90,
            periodDays: 30,
            dailyUsage: [],
            lifetime: nil
        )

        tracker.apply(CostSummaryBuilder.CostSummaryScan(summary: whole))

        XCTAssertEqual(tracker.costSummary?.totalCostUSD, 9)
        XCTAssertNotEqual(tracker.lastScanDate, previous)
    }

    @MainActor
    func testCancelledScanLeavesBothTheSummaryAndTheScanClockAlone() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let tracker = makeApplyTracker(lastScan: previous)
        let before = tracker.costSummary?.totalCostUSD

        // No slice completed, so there is nothing to publish and nothing learned.
        tracker.apply(nil)

        XCTAssertEqual(tracker.costSummary?.totalCostUSD, before)
        XCTAssertEqual(tracker.lastScanDate, previous)
    }

    // MARK: - Cache round-trip

    /// The persisted payloads roll usage up in `[Date: TokenAccumulator]`
    /// dictionaries, and a `Date` key survives a round trip only while the
    /// encoder and decoder agree on a date strategy. They fail *silently* when
    /// they drift: every strategy but `.iso8601` writes a bare number, so a
    /// mismatched pair still decodes — into the wrong day. Every daily row would
    /// land in a bucket decades away with nothing thrown, so pin the invariant
    /// here rather than trusting two defaults to stay matched.
    func testDateKeyedDailyRollupsSurviveACacheRoundTrip() throws {
        let store = try makeScanCacheStore()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        var totals = ClaudeFileTotals()
        totals.period.daily[day] = TokenAccumulator(input: 11, output: 22)

        var cache = CostScanFileCache<ClaudeFileTotals>()
        cache.records["/transcripts/a.jsonl"] = CostScanFileRecord(
            offset: 512,
            stamp: CostScanFileStamp(size: 4_096, modified: 1_780_000_000, fileID: 42),
            cutoff: day,
            isComplete: false,
            payload: totals
        )
        try store.saveClaude(cache)

        let loaded = store.loadClaude()
        let record = try XCTUnwrap(loaded.records["/transcripts/a.jsonl"])
        XCTAssertEqual(record.cutoff, day)
        XCTAssertEqual(record.offset, 512)
        XCTAssertEqual(record.payload.period.daily[day]?.input, 11)
        XCTAssertEqual(record.payload.period.daily[day]?.output, 22)
    }

    func testPersistReportsCacheWriteFailureAndASuccessfulRetryPersists() throws {
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanBlocked-\(UUID().uuidString)")
        try Data().write(to: blockedDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: blockedDirectory) }

        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        let store = CostScanCacheStore(directory: blockedDirectory)
        let session = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        session.setClaudeRecord(
            CostScanFileRecord(
                offset: 512,
                stamp: CostScanFileStamp(size: 4_096, modified: 1_780_000_000, fileID: 42),
                cutoff: cutoff,
                isComplete: false,
                payload: ClaudeFileTotals()
            ),
            for: "/transcripts/a.jsonl"
        )

        XCTAssertEqual(session.persist(), CostScanPersistReport(claude: .failed, codex: .failed))
        // Nothing reached disk, so the offsets this slice committed are not
        // resumable — the next slice would re-read the same bytes.
        XCTAssertTrue(store.loadClaude().records.isEmpty)

        try FileManager.default.removeItem(at: blockedDirectory)

        XCTAssertEqual(session.persist(), .persisted)
        XCTAssertEqual(store.loadClaude().records["/transcripts/a.jsonl"]?.offset, 512)
    }

    /// The two caches are separate artifacts with separate failure modes, so one
    /// provider's blocked write says nothing about the other's. Reporting a
    /// shared verdict costs the healthy provider its resumable offsets: the
    /// slice loop stops, and its next slice re-reads bytes it already paid for.
    func testPersistIsolatesOneProvidersWriteFailureFromTheOthersProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanSplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // A directory standing where the Claude artifact belongs: that write
        // fails while the Codex artifact beside it lands normally.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(CostScanCacheStore.claudeFileName),
            withIntermediateDirectories: true
        )

        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        let stamp = CostScanFileStamp(size: 4_096, modified: 1_780_000_000, fileID: 42)
        let store = CostScanCacheStore(directory: directory)
        let session = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        session.setClaudeRecord(
            CostScanFileRecord(
                offset: 512, stamp: stamp, cutoff: cutoff, isComplete: false, payload: ClaudeFileTotals()
            ),
            for: "/transcripts/a.jsonl"
        )
        session.setCodexRecord(
            CostScanFileRecord(
                offset: 512, stamp: stamp, cutoff: cutoff, isComplete: false, payload: CodexFileTotals(cutoff: cutoff)
            ),
            for: "/rollouts/b.jsonl"
        )

        let report = session.persist()

        XCTAssertEqual(report.outcome(for: .claude), .failed)
        XCTAssertEqual(report.outcome(for: .codex), .persisted)
        XCTAssertTrue(store.loadClaude().records.isEmpty)
        XCTAssertEqual(store.loadCodex().records["/rollouts/b.jsonl"]?.offset, 512)
    }

    func testPersistReportsNoStoreAsUnavailableRatherThanPersisted() {
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        let session = CostScanSession(cutoff: cutoff, options: .unlimited, store: nil)
        session.setClaudeRecord(
            CostScanFileRecord(
                offset: 512,
                stamp: CostScanFileStamp(size: 4_096, modified: 1_780_000_000, fileID: 42),
                cutoff: cutoff,
                isComplete: false,
                payload: ClaudeFileTotals()
            ),
            for: "/transcripts/a.jsonl"
        )

        // A session with nowhere to write is not "persisted": the offsets it
        // committed die with it, so a later slice would start from zero.
        XCTAssertEqual(session.persist(), .unavailable)
    }

    // MARK: - Slice loop control

    func testAnotherSliceRunsOnlyWhenThePreviousOneLeftResumableProgress() {
        let partial = CostSummaryBuilder.CostSummaryScan(
            summary: makeEmptySummary(), deferredProviders: [.claude, .codex])
        let whole = CostSummaryBuilder.CostSummaryScan(summary: makeEmptySummary())
        let failed = CostScanPersistReport(claude: .failed, codex: .failed)

        XCTAssertTrue(CostTracker.shouldRunAnotherSlice(after: partial, persistence: .persisted))
        // A slice whose caches never landed leaves the store exactly as it found
        // it, so 63 more slices would re-read the same bytes and defer in the
        // same place.
        XCTAssertFalse(CostTracker.shouldRunAnotherSlice(after: partial, persistence: failed))
        // Same waste, different cause: with no store at all every slice rebuilds
        // an empty cache and re-reads the corpus from offset 0.
        XCTAssertFalse(CostTracker.shouldRunAnotherSlice(after: partial, persistence: .unavailable))
        XCTAssertFalse(CostTracker.shouldRunAnotherSlice(after: whole, persistence: .persisted))
    }

    /// The stop condition is per provider, not per slice: one provider that
    /// cannot write must not end the other's scan, and must not keep the loop
    /// alive once it is the only one left with work.
    func testAnotherSliceRunsWhileAnyDeferringProviderStillPersistsItsProgress() {
        let bothDeferred = CostSummaryBuilder.CostSummaryScan(
            summary: makeEmptySummary(), deferredProviders: [.claude, .codex])
        let claudeDeferred = CostSummaryBuilder.CostSummaryScan(
            summary: makeEmptySummary(), deferredProviders: [.claude])
        let report = CostScanPersistReport(claude: .failed, codex: .persisted)

        XCTAssertTrue(CostTracker.shouldRunAnotherSlice(after: bothDeferred, persistence: report))
        // Codex has finished; the only provider still deferring is the one whose
        // offsets never reach disk, so another slice would read the same bytes.
        XCTAssertFalse(CostTracker.shouldRunAnotherSlice(after: claudeDeferred, persistence: report))
        // ...and the mirror image: Codex still has work and can still resume it.
        XCTAssertTrue(
            CostTracker.shouldRunAnotherSlice(
                after: CostSummaryBuilder.CostSummaryScan(
                    summary: makeEmptySummary(), deferredProviders: [.codex]),
                persistence: report
            )
        )
    }

    /// Each scanner defers its own corpus. A shared flag would report Claude as
    /// unfinished because Codex ran out of budget, and the slice loop's
    /// per-provider stop condition reads this set.
    func testDeferringOneProviderLeavesTheOtherReportedAsFinished() {
        let session = CostScanSession(
            cutoff: Date(timeIntervalSince1970: 1_780_000_000), options: .unlimited, store: nil)

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.deferredProviders, [])

        session.noteDeferred(.codex)

        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.deferredProviders, [.codex])
    }

    private func makeEmptySummary() -> CostSummary {
        CostSummary(
            costs: [],
            totalCostUSD: 0,
            totalTokens: 0,
            periodDays: 30,
            dailyUsage: [],
            lifetime: nil
        )
    }

    // MARK: - Corpus fixtures

    private func makeTranscriptRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeScanCacheStore() throws -> CostScanCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CostScanCacheStore(directory: directory)
    }

    @discardableResult
    private func writeTranscript(
        in root: URL,
        name: String,
        modifiedAgo: TimeInterval,
        lines: [String]
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_780_000_000 - modifiedAgo)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}
