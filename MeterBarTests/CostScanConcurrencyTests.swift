import XCTest
@testable import MeterBar

/// Covers the concurrency layer sitting on top of the two cost scanners: files
/// are parsed in parallel, but their results are folded serially in input
/// order.
///
/// Every scan here runs twice over the same fixtures — once at `width: 1`
/// (which takes the plain sequential path) and once wide — and asserts the two
/// agree exactly, down to the bit pattern of every accumulated `Double`. That
/// is the property the parallel scan has to preserve: floating-point addition
/// is not associative, and Codex's dedup is first-event-wins, so "same totals"
/// is only true if the fold order is pinned.
final class CostScanConcurrencyTests: XCTestCase {
    /// Wide enough to interleave on any machine the suite runs on, and not tied
    /// to `activeProcessorCount` so the test means the same thing on a laptop
    /// and on CI.
    private let wide = 8

    // MARK: - Claude

    func testClaudeParallelScanMatchesSequentialScan() throws {
        let root = try makeClaudeProjectsRoot()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T00:00:00Z"))

        // Enough files to spill past a single batch, spread over several
        // projects, models, origins, and days — the parallel fold has to
        // reproduce every one of those breakdowns, not just the grand total.
        for index in 0..<60 {
            let project = "www/demo-\(index % 4)"
            let day = 10 + (index % 12)
            try writeClaudeTranscript(in: root, project: project, name: "session-\(index).jsonl", lines: [
                claudeEventLine(
                    timestamp: "2026-06-\(day)T09:00:00.000Z",
                    messageID: "msg-\(index)-a",
                    requestID: "req-\(index)-a",
                    model: index.isMultiple(of: 2) ? "claude-sonnet-4-5" : "claude-opus-4-1",
                    input: 100 + index,
                    output: 7 * index
                ),
                claudeEventLine(
                    timestamp: "2026-06-\(day)T09:05:00.000Z",
                    messageID: "msg-\(index)-b",
                    requestID: "req-\(index)-b",
                    model: "claude-haiku-4-5",
                    input: 3,
                    output: 11,
                    toolName: index.isMultiple(of: 3) ? "Skill" : "Bash"
                ),
                // Unkeyed: no messageID/requestID, so it never enters the dedup
                // map and is tallied in append order.
                claudeEventLine(
                    timestamp: "2026-06-\(day)T09:07:00.000Z",
                    messageID: nil,
                    requestID: nil,
                    input: 1,
                    output: 1
                )
            ])
        }

        let sequential = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: 1)
        let parallel = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: wide)

        XCTAssertGreaterThan(parallel.lifetime.input, 0, "fixture produced no usage")
        XCTAssertEqual(snapshot(parallel), snapshot(sequential))
        XCTAssertEqual(
            try claudeBreakdownJSON(parallel, cutoff: cutoff),
            try claudeBreakdownJSON(sequential, cutoff: cutoff)
        )
    }

    func testClaudeDeduplicationSurvivesTheParallelFold() throws {
        let root = try makeClaudeProjectsRoot()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T00:00:00Z"))

        // The same messageID:requestID retried either side of the cutoff. The
        // two windows keep separate dedup maps, so the period must see only the
        // in-window copy while lifetime collapses the pair to one event.
        try writeClaudeTranscript(in: root, project: "www/demo", name: "straddle.jsonl", lines: [
            claudeEventLine(timestamp: "2026-06-14T23:59:00.000Z", input: 100, output: 50),
            claudeEventLine(timestamp: "2026-06-15T00:01:00.000Z", input: 100, output: 50)
        ])
        // A duplicate of the same key in a *different* file: Claude dedups per
        // file, so this is a second billed event, and the parallel fold must
        // not "improve" on that.
        try writeClaudeTranscript(in: root, project: "www/other", name: "copy.jsonl", lines: [
            claudeEventLine(timestamp: "2026-06-16T00:01:00.000Z", input: 100, output: 50)
        ])

        for width in [1, wide] {
            let windows = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: width)
            XCTAssertEqual(windows.period.input, 200, "width \(width)")
            XCTAssertEqual(windows.period.output, 100, "width \(width)")
            XCTAssertEqual(windows.lifetime.input, 200, "width \(width)")
            XCTAssertEqual(windows.lifetime.output, 100, "width \(width)")
        }

        let sequential = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: 1)
        let parallel = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: wide)
        XCTAssertEqual(snapshot(parallel), snapshot(sequential))
    }

    func testClaudeScanSurvivesUnreadableAndMalformedTranscripts() throws {
        let root = try makeClaudeProjectsRoot()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        try writeClaudeTranscript(in: root, project: "www/demo", name: "good.jsonl", lines: [
            claudeEventLine(timestamp: "2026-06-15T10:00:00.000Z", input: 100, output: 50)
        ])
        try writeClaudeTranscript(in: root, project: "www/demo", name: "garbage.jsonl", lines: [
            "not json at all",
            "{\"timestamp\": \"2026-06-15T10:00:00.000Z\", \"message\": {",
            ""
        ])
        try writeUnreadableFile(at: root.appendingPathComponent("-x/locked.jsonl"))
        // A *directory* that looks like a transcript: the enumerator hands it
        // over, the reader can't open it, and the scan has to keep going.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-x/folder.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )

        for width in [1, wide] {
            let windows = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: width)
            XCTAssertEqual(windows.lifetime.input, 100, "width \(width)")
            XCTAssertEqual(windows.lifetime.output, 50, "width \(width)")
            XCTAssertEqual(windows.lifetime.sessions, 1, "width \(width)")
        }
    }

    func testClaudeSessionCountsOneSessionPerTranscriptWithUsage() throws {
        let root = try makeClaudeProjectsRoot()
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        for index in 0..<3 {
            try writeClaudeTranscript(in: root, project: "www/demo", name: "used-\(index).jsonl", lines: [
                claudeEventLine(
                    timestamp: "2026-06-15T10:00:00.000Z",
                    messageID: "msg-\(index)",
                    requestID: "req-\(index)",
                    input: 10,
                    output: 5
                )
            ])
        }
        try writeClaudeTranscript(in: root, project: "www/demo", name: "empty.jsonl", lines: [])
        try writeClaudeTranscript(in: root, project: "www/demo", name: "zero.jsonl", lines: [
            claudeEventLine(timestamp: "2026-06-15T10:00:00.000Z", messageID: "z", requestID: "z", input: 0, output: 0)
        ])

        for width in [1, wide] {
            let windows = ClaudeCostScanner.scanSessions(since: cutoff, projectRoots: [root], width: width)
            XCTAssertEqual(windows.lifetime.sessions, 3, "width \(width)")
            XCTAssertEqual(windows.period.sessions, 3, "width \(width)")
        }
    }

    // MARK: - Codex

    func testCodexParallelScanMatchesSequentialScan() throws {
        let directory = try makeTemporaryDirectory(named: "CodexRollouts")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T00:00:00Z"))
        let home = ServiceSupport.realHomeDirectory()

        for index in 0..<40 {
            let day = 10 + (index % 12)
            try writeCodexRollout(in: directory, path: "2026/06/\(day)/rollout-\(index).jsonl", lines: [
                codexSessionMetaLine(
                    timestamp: "2026-06-\(day)T08:00:00Z",
                    conversationID: "conv-\(index)",
                    originator: index.isMultiple(of: 3) ? "Codex Desktop" : "codex_cli_rs",
                    cwd: "\(home)/www/demo-\(index % 4)"
                ),
                // Lands before the file names a model, so it is parked and
                // back-filled — order-sensitive state the parallel parse has to
                // keep strictly inside its own file.
                codexUsageLine(
                    timestamp: "2026-06-\(day)T08:30:00Z",
                    conversationID: "conv-\(index)",
                    input: 500 + index,
                    output: 20 + index
                ),
                codexTurnContextLine(
                    timestamp: "2026-06-\(day)T09:00:00Z",
                    model: index.isMultiple(of: 2) ? "gpt-5.5" : "gpt-5.5-codex"
                ),
                codexUsageLine(
                    timestamp: "2026-06-\(day)T09:30:00Z",
                    conversationID: "conv-\(index)",
                    input: 1_000 + index,
                    output: 500 + index
                )
            ])
        }

        var sequential = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &sequential, width: 1)
        var parallel = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &parallel, width: wide)

        XCTAssertGreaterThan(parallel.lifetime.totals.input, 0, "fixture produced no usage")
        XCTAssertEqual(snapshot(parallel), snapshot(sequential))
    }

    func testCodexDeduplicationStaysGlobalAcrossFiles() throws {
        let directory = try makeTemporaryDirectory(named: "CodexRollouts")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T00:00:00Z"))

        // Codex dedups on timestamp+session+counts across *every* file, unlike
        // Claude's per-file map, so the same event copied into a sibling
        // rollout must still be billed once however the files are parsed.
        let duplicate = codexTokenLine(timestamp: "2026-06-16T10:00:00Z")
        try writeCodexRollout(in: directory, path: "a.jsonl", lines: [duplicate])
        try writeCodexRollout(in: directory, path: "b.jsonl", lines: [duplicate])
        // Before the cutoff: lifetime only, and deduplicated independently of
        // the period window's own key set.
        let old = codexTokenLine(timestamp: "2026-06-01T10:00:00Z", input: 77, output: 33)
        try writeCodexRollout(in: directory, path: "c.jsonl", lines: [old])
        try writeCodexRollout(in: directory, path: "d.jsonl", lines: [old])

        for width in [1, wide] {
            var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
            CodexCostScanner.scanRollouts(directory: directory, windows: &windows, width: width)

            XCTAssertEqual(windows.period.totals.input, 1_000, "width \(width)")
            XCTAssertEqual(windows.period.totals.output, 500, "width \(width)")
            XCTAssertEqual(windows.lifetime.totals.input, 1_077, "width \(width)")
            XCTAssertEqual(windows.lifetime.totals.output, 533, "width \(width)")
        }

        var sequential = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &sequential, width: 1)
        var parallel = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &parallel, width: wide)
        XCTAssertEqual(snapshot(parallel), snapshot(sequential))
    }

    func testCodexScanSurvivesUnreadableAndMalformedRollouts() throws {
        let directory = try makeTemporaryDirectory(named: "CodexRollouts")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        try writeCodexRollout(in: directory, path: "good.jsonl", lines: [
            codexTokenLine(timestamp: "2026-06-15T10:00:00Z")
        ])
        try writeCodexRollout(in: directory, path: "garbage.jsonl", lines: [
            "not json at all",
            "{\"payload\": {\"type\": \"token_count\"",
            ""
        ])
        try writeUnreadableFile(at: directory.appendingPathComponent("locked.jsonl"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )

        for width in [1, wide] {
            var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
            CodexCostScanner.scanRollouts(directory: directory, windows: &windows, width: width)

            XCTAssertEqual(windows.lifetime.totals.input, 1_000, "width \(width)")
            XCTAssertEqual(windows.lifetime.totals.output, 500, "width \(width)")
            XCTAssertEqual(windows.lifetime.sessionIDs, ["conv-1"], "width \(width)")
        }
    }

    func testCodexSessionCountsStayPerConversation() throws {
        let directory = try makeTemporaryDirectory(named: "CodexRollouts")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))

        for index in 0..<5 {
            try writeCodexRollout(in: directory, path: "rollout-\(index).jsonl", lines: [
                codexTokenLine(
                    timestamp: "2026-06-15T10:0\(index):00Z",
                    conversationID: "conv-\(index)",
                    input: 100 + index,
                    output: 10
                )
            ])
        }
        // Same conversation split across two rollouts: one session, not two.
        try writeCodexRollout(in: directory, path: "rollout-split.jsonl", lines: [
            codexTokenLine(timestamp: "2026-06-15T11:00:00Z", conversationID: "conv-0", input: 5, output: 5)
        ])

        for width in [1, wide] {
            var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
            CodexCostScanner.scanRollouts(directory: directory, windows: &windows, width: width)
            XCTAssertEqual(windows.lifetime.sessionIDs.count, 5, "width \(width)")
        }
    }

    // MARK: - Fan-out helper

    func testParseInOrderVisitsEveryInputExactlyOnceInOrder() {
        let inputs = Array(0..<257)

        for width in [1, 2, 3, wide, 64] {
            var folded: [Int] = []
            CostScanParallel.parseInOrder(
                inputs,
                width: width,
                parse: { $0 * 2 },
                fold: { folded.append($0) }
            )
            XCTAssertEqual(folded, inputs.map { $0 * 2 }, "width \(width)")
        }
    }

    func testParseInOrderToleratesEmptyInputAndNonPositiveWidth() {
        var folded: [Int] = []
        CostScanParallel.parseInOrder([Int](), width: wide, parse: { $0 }, fold: { folded.append($0) })
        XCTAssertEqual(folded, [])

        CostScanParallel.parseInOrder([1, 2, 3], width: 0, parse: { $0 }, fold: { folded.append($0) })
        XCTAssertEqual(folded, [1, 2, 3])
    }
}

// MARK: - Fixtures

extension CostScanConcurrencyTests {
    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeClaudeProjectsRoot() throws -> URL {
        try makeTemporaryDirectory(named: "ClaudeProjects")
    }

    /// Claude stores transcripts under `<root>/<encoded-cwd>/<session>.jsonl`,
    /// and `CostProjectAttribution` only recognizes an encoded directory that
    /// starts with the real home directory — so the fixture has to encode it
    /// the same way the CLI does.
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
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        model: String = "claude-sonnet-4-5",
        input: Int = 100,
        output: Int = 50,
        toolName: String? = nil
    ) -> String {
        let idPart = messageID.map { "\"id\": \"\($0)\"," } ?? ""
        let requestPart = requestID.map { "\"requestId\": \"\($0)\"," } ?? ""
        let contentPart = toolName.map {
            "\"content\": [{\"type\": \"tool_use\", \"name\": \"\($0)\"}],"
        } ?? ""
        return """
        {"timestamp": "\(timestamp)", \(requestPart) "message": {\(idPart) "model": "\(model)", \
        \(contentPart) "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    private func writeCodexRollout(in root: URL, path: String, lines: [String]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func codexSessionMetaLine(
        timestamp: String,
        conversationID: String = "conv-1",
        originator: String = "Codex Desktop",
        cwd: String? = nil
    ) -> String {
        let cwdPart = cwd.map { "\"cwd\": \"\($0)\"," } ?? ""
        return """
        {"timestamp": "\(timestamp)", "type": "session_meta", "payload": \
        {"id": "\(conversationID)", "originator": "\(originator)", \(cwdPart) "cli_version": "0.0.0"}}
        """
    }

    private func codexTurnContextLine(timestamp: String, model: String) -> String {
        """
        {"timestamp": "\(timestamp)", "type": "turn_context", "payload": \
        {"model": "\(model)", "effort": "high", "summary": "auto"}}
        """
    }

    /// A `token_count` event with no model on it — attribution has to come from
    /// the surrounding rollout.
    private func codexUsageLine(
        timestamp: String,
        conversationID: String = "conv-1",
        input: Int = 1_000,
        output: Int = 500
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "type": "event_msg", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": 200, "reasoning_output_tokens": 50}}}}
        """
    }

    /// A `token_count` event that names its own model.
    private func codexTokenLine(
        timestamp: String,
        conversationID: String = "conv-1",
        model: String = "gpt-5.5",
        input: Int = 1_000,
        output: Int = 500
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"model": "\(model)", "last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": 200, "reasoning_output_tokens": 50}}}}
        """
    }

    /// A transcript the scan can see but not open. Restored to readable on
    /// teardown so the temp directory can be removed.
    private func writeUnreadableFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{\"timestamp\": \"2026-06-15T10:00:00.000Z\"}".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Snapshots

extension CostScanConcurrencyTests {
    /// Flattens a window pair into plain strings so `XCTAssertEqual` prints a
    /// usable diff instead of two walls of nested dictionaries.
    private func snapshot(_ windows: ScanWindows<ClaudeSessionTotals>) -> [String: String] {
        prefixed("period", snapshot(windows.period))
            .merging(prefixed("lifetime", snapshot(windows.lifetime))) { lhs, _ in lhs }
    }

    private func snapshot(_ windows: ScanWindows<CodexScanContext>) -> [String: String] {
        prefixed("period", snapshot(windows.period))
            .merging(prefixed("lifetime", snapshot(windows.lifetime))) { lhs, _ in lhs }
    }

    private func snapshot(_ totals: ClaudeSessionTotals) -> [String: String] {
        var result: [String: String] = [
            "input": "\(totals.input)",
            "output": "\(totals.output)",
            "cacheCreation": "\(totals.cacheCreation)",
            "cacheRead": "\(totals.cacheRead)",
            "estimatedCost": exact(totals.estimatedCost),
            "sessions": "\(totals.sessions)",
            "earliest": describe(totals.earliest),
            "latest": describe(totals.latest)
        ]
        merge(&result, "daily", totals.daily)
        merge(&result, "models", totals.models)
        merge(&result, "origins", totals.origins)
        merge(&result, "projects", totals.projects)
        merge(&result, "dailyModels", totals.dailyModels)
        merge(&result, "dailyProjects", totals.dailyProjects)
        merge(&result, "projectModels", totals.projectModels)
        merge(&result, "dailyProjectModels", totals.dailyProjectModels)
        return result
    }

    private func snapshot(_ context: CodexScanContext) -> [String: String] {
        var result: [String: String] = [
            "totals": describe(context.totals),
            "sessionIDs": context.sessionIDs.sorted().joined(separator: ","),
            "eventKeys": context.eventKeys.sorted().joined(separator: ","),
            "earliest": describe(context.earliestDate),
            "latest": describe(context.latestDate)
        ]
        merge(&result, "daily", context.dailyTotals)
        merge(&result, "models", context.modelTotals)
        merge(&result, "origins", context.originTotals)
        merge(&result, "projects", context.projectTotals)
        merge(&result, "dailyModels", context.dailyModelTotals)
        merge(&result, "dailyProjects", context.dailyProjectTotals)
        merge(&result, "projectModels", context.projectModelTotals)
        merge(&result, "dailyProjectModels", context.dailyProjectModelTotals)
        return result
    }

    /// The per-model / per-origin / per-project / per-day breakdowns exactly as
    /// the summary publishes them, not just the accumulators behind them.
    private func claudeBreakdownJSON(
        _ windows: ScanWindows<ClaudeSessionTotals>,
        cutoff: Date
    ) throws -> String {
        let scan = try XCTUnwrap(ClaudeCostScanner.makeCost(from: windows.period, windowStart: cutoff))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cost = try encoder.encode([
            scan.0.modelBreakdowns,
            scan.0.originBreakdowns,
            scan.0.projectBreakdowns
        ])
        let daily = try encoder.encode(scan.1.sorted { $0.date < $1.date })
        return String(decoding: cost + daily, as: UTF8.self)
    }

    private func prefixed(_ prefix: String, _ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            result["\(prefix).\(key)"] = value
        }
        return result
    }

    private func merge(_ result: inout [String: String], _ label: String, _ values: [String: TokenAccumulator]) {
        for (name, tokens) in values {
            result["\(label)|\(name)"] = describe(tokens)
        }
    }

    private func merge(_ result: inout [String: String], _ label: String, _ values: [Date: TokenAccumulator]) {
        for (day, tokens) in values {
            result["\(label)|\(describe(day))"] = describe(tokens)
        }
    }

    private func merge(
        _ result: inout [String: String],
        _ label: String,
        _ values: [String: [String: TokenAccumulator]]
    ) {
        for (outer, inner) in values {
            merge(&result, "\(label)|\(outer)", inner)
        }
    }

    private func merge(
        _ result: inout [String: String],
        _ label: String,
        _ values: [Date: [String: TokenAccumulator]]
    ) {
        for (day, inner) in values {
            merge(&result, "\(label)|\(describe(day))", inner)
        }
    }

    private func merge(
        _ result: inout [String: String],
        _ label: String,
        _ values: [Date: [String: [String: TokenAccumulator]]]
    ) {
        for (day, inner) in values {
            merge(&result, "\(label)|\(describe(day))", inner)
        }
    }

    private func describe(_ tokens: TokenAccumulator) -> String {
        [
            "\(tokens.input)", "\(tokens.output)", "\(tokens.cacheCreation)",
            "\(tokens.cacheRead)", "\(tokens.reasoning)", "\(tokens.events)",
            exact(tokens.estimatedCostUSD)
        ].joined(separator: "/")
    }

    private func describe(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return "\(date.timeIntervalSince1970)"
    }

    /// Bit pattern, not `==`: the whole point of folding in a fixed order is
    /// that the sums agree to the last ulp, and a tolerance-based comparison
    /// would pass even if they didn't.
    private func exact(_ value: Double) -> String {
        "\(value.bitPattern)"
    }
}
