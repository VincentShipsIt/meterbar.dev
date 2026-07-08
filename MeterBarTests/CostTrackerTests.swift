import XCTest
@testable import MeterBar

/// First direct coverage for CostTracker's parsing/pricing internals — the
/// audit found ~1,000 lines of money math with zero tests, which is exactly
/// where the CLI-vs-app cost divergence hid.
final class CostTrackerTests: XCTestCase {
    // MARK: - Model-id normalization

    func testNormalizeClaudeModelStripsDateSuffix() {
        XCTAssertEqual(CostTracker.normalizeClaudeModel("claude-opus-4-8-20260101"), "claude-opus-4-8")
        XCTAssertEqual(CostTracker.normalizeClaudeModel("claude-fable-5-20260315"), "claude-fable-5")
    }

    func testNormalizeClaudeModelStripsBedrockStylePrefixes() {
        XCTAssertEqual(CostTracker.normalizeClaudeModel("anthropic.claude-sonnet-4-5"), "claude-sonnet-4-5")
        XCTAssertEqual(CostTracker.normalizeClaudeModel("us.anthropic.claude-opus-4-8"), "claude-opus-4-8")
    }

    func testNormalizeClaudeModelStripsVersionSuffix() {
        XCTAssertEqual(CostTracker.normalizeClaudeModel("anthropic.claude-sonnet-4-5-v1:0"), "claude-sonnet-4-5")
    }

    func testNormalizeClaudeModelPassesThroughCleanIds() {
        XCTAssertEqual(CostTracker.normalizeClaudeModel("claude-fable-5"), "claude-fable-5")
        XCTAssertEqual(CostTracker.normalizeClaudeModel("  claude-haiku-4-5 "), "claude-haiku-4-5")
    }

    // MARK: - Pricing lookup

    func testClaudePricingExactAndFamilyMatches() {
        XCTAssertEqual(CostTracker.claudePricing(for: "claude-fable-5").input, 10.0)
        // Dated ids normalize onto the base id.
        XCTAssertEqual(CostTracker.claudePricing(for: "claude-opus-4-8-20260101").input, 5.0)
        // Family fallback for unknown fable variants.
        XCTAssertEqual(CostTracker.claudePricing(for: "claude-fable-9").input, 10.0)
        // Unknown models get the default (sonnet-rate) pricing.
        XCTAssertEqual(CostTracker.claudePricing(for: "mystery-model").input, 3.0)
        XCTAssertEqual(CostTracker.claudePricing(for: nil).input, 3.0)
    }

    // MARK: - Cost formula

    func testCalculateCostMatchesClaudeCostWithoutOneHourTier() {
        let pricing = TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)

        let simple = CostTracker.calculateCost(
            input: 1_000_000, output: 2_000_000, cacheCreation: 500_000, cacheRead: 4_000_000, pricing: pricing
        )
        let claude = CostTracker.calculateClaudeCost(
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
        let cost = CostTracker.calculateCost(input: -500, output: -1, cacheCreation: -2, cacheRead: -3, pricing: pricing)
        XCTAssertEqual(cost, 0, accuracy: 0.0001)
    }

    func testOneHourCacheTierPricedSeparately() {
        let pricing = TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0)
        let cost = CostTracker.calculateClaudeCost(
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
        let result = CostTracker.parseSessionFile(at: url, since: cutoff)

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
        let result = CostTracker.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 42)
        XCTAssertEqual(result.output, 8)
    }

    func testParseSessionFileAppliesPerModelPricing() throws {
        // 1M input on sonnet pricing = $3.00 exactly.
        let url = try writeSessionFile(lines: [
            eventLine(timestamp: "2026-07-01T10:00:00.000Z", input: 1_000_000, output: 0)
        ])

        let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z")!
        let result = CostTracker.parseSessionFile(at: url, since: cutoff)

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
        let result = CostTracker.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 5)
    }

    // MARK: - Codex archived-session scan

    /// Writes a `.jsonl` into an `archived_sessions` directory and returns that
    /// directory (the argument `scanCodexArchivedSessions` expects). The file's
    /// modification date is "now", so it passes the per-file mtime cutoff.
    private func writeCodexArchive(lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexArchive-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return dir
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

    func testScanCodexArchivedSessionsAccumulatesTokenCounts() throws {
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostTracker.scanCodexArchivedSessions(directory: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 1_000)
        // output accumulates the reasoning tokens on the daily/model rollups, but
        // `totals` keeps output and reasoning separate.
        XCTAssertEqual(context.totals.output, 500)
        XCTAssertEqual(context.totals.reasoning, 50)
        XCTAssertEqual(context.totals.cacheRead, 200)
        XCTAssertEqual(context.sessionIDs, ["conv-1"])
    }

    func testScanCodexArchivedSessionsDeduplicatesIdenticalEvents() throws {
        let line = codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        let dir = try writeCodexArchive(lines: [line, line])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostTracker.scanCodexArchivedSessions(directory: dir, since: cutoff, context: &context)

        // Identical events collapse to one via the dedup key.
        XCTAssertEqual(context.totals.input, 1_000)
        XCTAssertEqual(context.totals.output, 500)
    }

    func testScanCodexArchivedSessionsHonorsPerLineCutoff() throws {
        let dir = try writeCodexArchive(lines: [
            codexTokenLine(timestamp: "2025-01-01T00:00:00Z", conversationID: "old", input: 9_999),
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z", conversationID: "new", input: 100)
        ])
        let cutoff = FlexibleISO8601.date(from: "2026-01-01T00:00:00Z")!
        var context = makeContext(cutoff: cutoff)

        CostTracker.scanCodexArchivedSessions(directory: dir, since: cutoff, context: &context)

        // Only the post-cutoff line is counted.
        XCTAssertEqual(context.totals.input, 100)
        XCTAssertEqual(context.sessionIDs, ["new"])
    }
}
