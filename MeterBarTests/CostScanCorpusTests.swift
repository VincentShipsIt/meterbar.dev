import XCTest
@testable import MeterBar

/// Covers what a scan over a whole fixture corpus has to get right regardless of
/// how it reaches the files: deduplication, session counting, and surviving
/// transcripts it cannot read.
final class CostScanCorpusTests: XCTestCase {
    // MARK: - Claude

    func testClaudeDeduplicationIsPerFileAndPerWindow() throws {
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
        // file, so this is a second billed event.
        try writeClaudeTranscript(in: root, project: "www/other", name: "copy.jsonl", lines: [
            claudeEventLine(timestamp: "2026-06-16T00:01:00.000Z", input: 100, output: 50)
        ])

        let windows = ClaudeCostScanner.scanRoots([root], session: makeSession(cutoff: cutoff))

        XCTAssertEqual(windows.period.input, 200)
        XCTAssertEqual(windows.period.output, 100)
        XCTAssertEqual(windows.lifetime.input, 200)
        XCTAssertEqual(windows.lifetime.output, 100)
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

        let windows = ClaudeCostScanner.scanRoots([root], session: makeSession(cutoff: cutoff))

        XCTAssertEqual(windows.lifetime.input, 100)
        XCTAssertEqual(windows.lifetime.output, 50)
        XCTAssertEqual(windows.lifetime.sessions, 1)
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

        let windows = ClaudeCostScanner.scanRoots([root], session: makeSession(cutoff: cutoff))

        XCTAssertEqual(windows.lifetime.sessions, 3)
        XCTAssertEqual(windows.period.sessions, 3)
    }

    func testClaudeScanAccumulatesOnlyTrailingSevenDaysIntoHourlyBuckets() throws {
        let root = try makeClaudeProjectsRoot()
        let periodCutoff = try date("2025-05-17T00:00:00Z")
        let hourlyCutoff = try date("2025-06-09T00:00:00Z")
        try writeClaudeTranscript(in: root, project: "www/demo", name: "hours.jsonl", lines: [
            claudeEventLine(timestamp: "2025-06-08T23:59:00Z", messageID: "old", requestID: "old", input: 90),
            claudeEventLine(timestamp: "2025-06-09T00:00:00Z", messageID: "edge", requestID: "edge", input: 50),
            claudeEventLine(timestamp: "2025-06-14T10:59:00Z", messageID: "a", requestID: "a", input: 100),
            claudeEventLine(timestamp: "2025-06-14T11:00:00Z", messageID: "b", requestID: "b", input: 200),
        ])

        let session = CostScanSession(
            cutoff: periodCutoff,
            hourlyCutoff: hourlyCutoff,
            options: .unlimited
        )
        let rows = try XCTUnwrap(ClaudeCostScanner.makeCost(
            from: ClaudeCostScanner.scanRoots([root], session: session).period,
            windowStart: periodCutoff
        )?.2)

        XCTAssertEqual(rows.map(\.inputTokens).sorted(), [50, 100, 200])
        XCTAssertEqual(rows.map(\.provider), [.claudeCode, .claudeCode, .claudeCode])
        XCTAssertEqual(rows.map { calendarHour($0.date) }.sorted(), [0, 10, 11])
    }

    // MARK: - Codex

    func testCodexDeduplicationStaysGlobalAcrossFiles() throws {
        let directory = try makeTemporaryDirectory(named: "CodexRollouts")
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-15T00:00:00Z"))

        // Codex dedups on timestamp+session+counts across *every* file, unlike
        // Claude's per-file map, so the same event copied into a sibling
        // rollout must still be billed once.
        let duplicate = codexTokenLine(timestamp: "2026-06-16T10:00:00Z")
        try writeCodexRollout(in: directory, path: "a.jsonl", lines: [duplicate])
        try writeCodexRollout(in: directory, path: "b.jsonl", lines: [duplicate])
        // Before the cutoff: lifetime only, and deduplicated independently of
        // the period window's own key set.
        let old = codexTokenLine(timestamp: "2026-06-01T10:00:00Z", input: 77, output: 33)
        try writeCodexRollout(in: directory, path: "c.jsonl", lines: [old])
        try writeCodexRollout(in: directory, path: "d.jsonl", lines: [old])

        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
        CostScanFixtureScan.codexRollouts(in: directory, windows: &windows)

        XCTAssertEqual(windows.period.totals.input, 1_000)
        XCTAssertEqual(windows.period.totals.output, 500)
        XCTAssertEqual(windows.lifetime.totals.input, 1_077)
        XCTAssertEqual(windows.lifetime.totals.output, 533)
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

        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
        CostScanFixtureScan.codexRollouts(in: directory, windows: &windows)

        XCTAssertEqual(windows.lifetime.totals.input, 1_000)
        XCTAssertEqual(windows.lifetime.totals.output, 500)
        XCTAssertEqual(windows.lifetime.sessionIDs, ["conv-1"])
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

        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)
        CostScanFixtureScan.codexRollouts(in: directory, windows: &windows)

        XCTAssertEqual(windows.lifetime.sessionIDs.count, 5)
    }

    func testCodexScanAccumulatesOnlyTrailingSevenDaysIntoHourlyBuckets() throws {
        let directory = try makeTemporaryDirectory(named: "CodexHourlyRollouts")
        let periodCutoff = try date("2025-05-17T00:00:00Z")
        let hourlyCutoff = try date("2025-06-09T00:00:00Z")
        try writeCodexRollout(in: directory, path: "hours.jsonl", lines: [
            codexTokenLine(timestamp: "2025-06-08T23:59:00Z", conversationID: "old", input: 90),
            codexTokenLine(timestamp: "2025-06-09T00:00:00Z", conversationID: "edge", input: 50),
            codexTokenLine(timestamp: "2025-06-14T10:59:00Z", conversationID: "a", input: 100),
            codexTokenLine(timestamp: "2025-06-14T11:00:00Z", conversationID: "b", input: 200),
        ])

        var windows = CodexCostScanner.scanWindows(cutoff: periodCutoff, hourlyCutoff: hourlyCutoff)
        CostScanFixtureScan.codexRollouts(in: directory, windows: &windows)
        let rows = try XCTUnwrap(CodexCostScanner.makeCost(from: windows.period)?.2)

        XCTAssertEqual(rows.map(\.inputTokens).sorted(), [0, 0, 0])
        XCTAssertEqual(rows.map(\.cacheReadTokens).sorted(), [200, 200, 200])
        XCTAssertEqual(rows.map(\.provider), [.codexCli, .codexCli, .codexCli])
        XCTAssertEqual(rows.map { calendarHour($0.date) }.sorted(), [0, 10, 11])
    }
}

// MARK: - Fixtures

extension CostScanCorpusTests {
    /// Unbounded so the whole fixture corpus is read in one pass; the budget
    /// itself is covered by `CostScanCollaboratorTests`.
    private func makeSession(cutoff: Date) -> CostScanSession {
        CostScanSession(cutoff: cutoff, options: .unlimited)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(FlexibleISO8601.date(from: value))
    }

    private func calendarHour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.component(.hour, from: date)
    }

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

    private func writeCodexRollout(in root: URL, path: String, lines: [String]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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
