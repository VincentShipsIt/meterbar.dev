import XCTest
@testable import MeterBar
import MeterBarShared

/// Covers the oversized-line guard both cost scanners apply before handing a
/// transcript line to `JSONSerialization`.
///
/// The fixtures here are deliberately *valid* usage records that are merely too
/// large: a malformed line was already skipped by the existing parse guards, so
/// only a well-formed giant proves the size check is what rejected it. Each
/// oversized fixture sits one byte above `CostScanFileSystem.maximumLineBytes`
/// and each accepted fixture sits exactly on it, which pins the boundary rather
/// than testing somewhere vaguely near it.
final class OversizedScanLineTests: XCTestCase {
    private var cap: Int { CostScanFileSystem.maximumLineBytes }

    // MARK: - Fixtures

    /// Inflates an ASCII JSON object to exactly `target` bytes by appending a
    /// top-level padding string. The object stays parseable, so a scanner that
    /// skips it can only have skipped it on size.
    private func grown(_ json: String, toBytes target: Int) -> String {
        let prefix = String(json.dropLast()) + ",\"padding\":\""
        let suffix = "\"}"
        let fill = max(0, target - prefix.utf8.count - suffix.utf8.count)
        return prefix + String(repeating: "x", count: fill) + suffix
    }

    private func writeTranscript(lines: [String], named name: String = "session.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OversizedScanLineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// Writes a rollout into an `archived_sessions` directory and returns that
    /// directory — the argument `CodexCostScanner.scanRollouts` expects.
    private func writeCodexArchive(lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OversizedCodexHome-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return dir
    }

    private func claudeUsageLine(
        timestamp: String,
        messageID: String = "msg_1",
        requestID: String = "req_1",
        input: Int = 10,
        output: Int = 5
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "requestId": "\(requestID)", "message": {"id": "\(messageID)", \
        "model": "claude-sonnet-4-5", "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    private func codexUsageLine(
        timestamp: String,
        conversationID: String = "conv-1",
        input: Int = 1_000,
        output: Int = 500
    ) -> String {
        """
        {"timestamp": "\(timestamp)", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(conversationID)"}, \
        "info": {"model": "gpt-5.5", "last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": 0, "reasoning_output_tokens": 0}}}}
        """
    }

    private let cutoff = FlexibleISO8601.date(from: "2026-06-01T00:00:00Z") ?? .distantPast

    // MARK: - Claude

    func testClaudeSkipsUsageLinesAboveTheCap() throws {
        let url = try writeTranscript(lines: [
            grown(claudeUsageLine(timestamp: "2026-07-01T10:00:00.000Z"), toBytes: cap + 1)
        ])

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 0)
        XCTAssertEqual(windows.period.output, 0)
        XCTAssertEqual(windows.period.estimatedCost, 0, accuracy: 0.0001)
        // No usage means no session either: a file of nothing but giants is not
        // a session that spent anything.
        XCTAssertEqual(windows.period.sessions, 0)
    }

    func testClaudeParsesUsageLinesExactlyAtTheCap() throws {
        let url = try writeTranscript(lines: [
            grown(claudeUsageLine(timestamp: "2026-07-01T10:00:00.000Z"), toBytes: cap)
        ])

        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        XCTAssertEqual(result.input, 10)
        XCTAssertEqual(result.output, 5)
        XCTAssertEqual(result.sessions, 1)
    }

    func testClaudeOversizedLineDoesNotAbortTheRestOfTheFile() throws {
        let url = try writeTranscript(lines: [
            claudeUsageLine(timestamp: "2026-07-01T10:00:00.000Z", messageID: "a", requestID: "a", input: 10),
            grown(
                claudeUsageLine(
                    timestamp: "2026-07-01T10:30:00.000Z", messageID: "big", requestID: "big",
                    input: 999_999, output: 999_999
                ),
                toBytes: cap + 1
            ),
            claudeUsageLine(timestamp: "2026-07-01T11:00:00.000Z", messageID: "b", requestID: "b", input: 7, output: 3)
        ])

        let result = ClaudeCostScanner.parseSessionFile(at: url, since: cutoff)

        // Both normal events survive: the skip is per line, not per file.
        XCTAssertEqual(result.input, 17)
        XCTAssertEqual(result.output, 8)
    }

    func testClaudeCapAppliesToBothWindows() throws {
        let url = try writeTranscript(lines: [
            claudeUsageLine(
                timestamp: "2026-05-01T10:00:00.000Z", messageID: "old", requestID: "old", input: 4, output: 1
            ),
            grown(
                claudeUsageLine(
                    timestamp: "2026-05-02T10:00:00.000Z", messageID: "old-big", requestID: "old-big",
                    input: 100_000, output: 100_000
                ),
                toBytes: cap + 1
            ),
            claudeUsageLine(
                timestamp: "2026-07-01T10:00:00.000Z", messageID: "new", requestID: "new", input: 10, output: 5
            ),
            grown(
                claudeUsageLine(
                    timestamp: "2026-07-02T10:00:00.000Z", messageID: "new-big", requestID: "new-big",
                    input: 200_000, output: 200_000
                ),
                toBytes: cap + 1
            )
        ])

        let windows = ClaudeCostScanner.parseSessionWindows(at: url, since: cutoff)

        XCTAssertEqual(windows.period.input, 10)
        XCTAssertEqual(windows.period.output, 5)
        // The lifetime window reads every line the period window skipped plus
        // the pre-cutoff ones, so it is where an unguarded giant would show up.
        XCTAssertEqual(windows.lifetime.input, 14)
        XCTAssertEqual(windows.lifetime.output, 6)
    }

    // MARK: - Codex

    func testCodexSkipsUsageLinesAboveTheCap() throws {
        let dir = try writeCodexArchive(lines: [
            grown(codexUsageLine(timestamp: "2026-07-01T10:00:00Z"), toBytes: cap + 1)
        ])
        var context = CodexScanContext(earliestDate: Date(), latestDate: cutoff)

        CodexCostScanner.scanRollouts(directory: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 0)
        XCTAssertEqual(context.totals.output, 0)
        XCTAssertTrue(context.sessionIDs.isEmpty)
    }

    func testCodexParsesUsageLinesExactlyAtTheCap() throws {
        let dir = try writeCodexArchive(lines: [
            grown(codexUsageLine(timestamp: "2026-07-01T10:00:00Z"), toBytes: cap)
        ])
        var context = CodexScanContext(earliestDate: Date(), latestDate: cutoff)

        CodexCostScanner.scanRollouts(directory: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 1_000)
        XCTAssertEqual(context.totals.output, 500)
        XCTAssertEqual(context.sessionIDs, ["conv-1"])
    }

    func testCodexOversizedLineDoesNotAbortTheRestOfTheFile() throws {
        let dir = try writeCodexArchive(lines: [
            codexUsageLine(timestamp: "2026-07-01T10:00:00Z", input: 1_000, output: 500),
            grown(
                codexUsageLine(timestamp: "2026-07-01T10:30:00Z", input: 999_999, output: 999_999),
                toBytes: cap + 1
            ),
            codexUsageLine(timestamp: "2026-07-01T11:00:00Z", input: 7, output: 3)
        ])
        var context = CodexScanContext(earliestDate: Date(), latestDate: cutoff)

        CodexCostScanner.scanRollouts(directory: dir, since: cutoff, context: &context)

        XCTAssertEqual(context.totals.input, 1_007)
        XCTAssertEqual(context.totals.output, 503)
    }

    func testCodexCapAppliesToBothWindows() throws {
        let dir = try writeCodexArchive(lines: [
            codexUsageLine(timestamp: "2026-05-01T10:00:00Z", input: 4, output: 1),
            grown(
                codexUsageLine(timestamp: "2026-05-02T10:00:00Z", input: 100_000, output: 100_000),
                toBytes: cap + 1
            ),
            codexUsageLine(timestamp: "2026-07-01T10:00:00Z", input: 10, output: 5),
            grown(
                codexUsageLine(timestamp: "2026-07-02T10:00:00Z", input: 200_000, output: 200_000),
                toBytes: cap + 1
            )
        ])
        var windows = CodexCostScanner.scanWindows(cutoff: cutoff)

        CodexCostScanner.scanRollouts(directory: dir, windows: &windows)

        XCTAssertEqual(windows.period.totals.input, 10)
        XCTAssertEqual(windows.period.totals.output, 5)
        XCTAssertEqual(windows.lifetime.totals.input, 14)
        XCTAssertEqual(windows.lifetime.totals.output, 6)
    }
}
