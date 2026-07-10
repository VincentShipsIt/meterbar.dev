import XCTest
@testable import MeterBar

/// Coverage for #95: native discovery, terminal-state classification, and the
/// replay ledger. Fixtures mirror the real Claude Code JSONL schema
/// (`type:"assistant"`, `isApiErrorMessage:true`, `apiErrorStatus:429`,
/// `message.content[].text`).
final class SessionWakeDiscoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture builders

    private func ts(_ iso: String) -> String { iso }

    private func assistantText(_ text: String, timestamp: String, cwd: String, sidechain: Bool = false) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "isSidechain": sidechain,
            "cwd": cwd,
            "sessionId": "s",
            "gitBranch": "main",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]]
        ]
        return jsonLine(object)
    }

    private func rateLimit(_ text: String, timestamp: String, cwd: String, status: Int = 429, sidechain: Bool = false) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "isApiErrorMessage": true,
            "apiErrorStatus": status,
            "isSidechain": sidechain,
            "cwd": cwd,
            "sessionId": "s",
            "gitBranch": "main",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]]
        ]
        return jsonLine(object)
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @discardableResult
    private func writeTranscript(
        account: String = "acct",
        project: String = "-Users-me-proj",
        session: String = "session-a",
        lines: [String]
    ) throws -> URL {
        let dir = tempDir
            .appendingPathComponent(account)
            .appendingPathComponent("projects")
            .appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func accountConfigDir(_ account: String = "acct") -> String {
        tempDir.appendingPathComponent(account).path
    }

    // MARK: - Classifier: latest-decisive-event

    func testHistoricalRateLimitFollowedByProgressIsNotBlocked() {
        let cwd = tempDir.path
        let lines = [
            rateLimit("You've hit your session limit · resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd),
            assistantText("Resumed work and finished the task.", timestamp: "2026-07-10T03:30:00.000Z", cwd: cwd)
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        if case .active = summary.state {} else {
            XCTFail("Expected active after later progress, got \(summary.state)")
        }
    }

    func testLatestEventBlockedIsBlocked() {
        let cwd = tempDir.path
        let lines = [
            assistantText("Working…", timestamp: "2026-07-10T01:00:00.000Z", cwd: cwd),
            rateLimit("You've hit your session limit · resets 7:30am (Europe/Malta)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        guard case let .blocked(reason, _, _) = summary.state else {
            return XCTFail("Expected blocked, got \(summary.state)")
        }
        XCTAssertEqual(reason, .sessionLimit)
    }

    func testCasingAndMarkdownVariantsClassify() {
        let cwd = tempDir.path
        let variants = [
            "You've hit your session limit · resets **2:10am (Europe/Malta)**",
            "you've hit your USAGE LIMIT · resets 2:30am",
            "Claude AI usage limit reached · resets 9:00pm (America/New_York)"
        ]
        for text in variants {
            let summary = TranscriptClassifier.classify(
                sessionID: "s",
                lines: [rateLimit(text, timestamp: "2026-07-10T00:00:00.000Z", cwd: cwd)]
            )
            guard case .blocked = summary.state else {
                return XCTFail("Variant not classified as blocked: \(text)")
            }
        }
    }

    func testWeeklyAndModelWeeklyReasons() {
        XCTAssertEqual(WakeBlockReason.classify(messageText: "You've hit your weekly limit"), .weeklyLimit)
        XCTAssertEqual(WakeBlockReason.classify(messageText: "Opus weekly limit reached"), .modelWeeklyLimit)
        XCTAssertEqual(WakeBlockReason.classify(messageText: "session limit"), .sessionLimit)
        XCTAssertEqual(WakeBlockReason.classify(messageText: "some other limit"), .usageLimit)
    }

    func testMissingStatusCodeFallsBackToMessageBody() {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T00:00:00.000Z",
            "isApiErrorMessage": true,
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": ["role": "assistant", "content": [["type": "text", "text": "usage limit reached, resets 1:00am"]]]
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: [jsonLine(object)])
        guard case .blocked = summary.state else {
            return XCTFail("Expected blocked from message body, got \(summary.state)")
        }
    }

    func testMalformedAndTruncatedLinesDoNotCrash() {
        let cwd = tempDir.path
        let lines = [
            "{not valid json",
            "",
            "[1,2,3]",
            "\"a bare string\"",
            rateLimit("You've hit your session limit · resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd),
            "{\"type\":\"assistant\",\"timestamp\":\"broken" // truncated final line
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        guard case .blocked = summary.state else {
            return XCTFail("Expected blocked despite malformed lines, got \(summary.state)")
        }
    }

    // MARK: - Reset parser

    func testResetJustPassedDoesNotRollToTomorrow() throws {
        // "02:10 reset read at 02:15" must resolve to today 02:10, not tomorrow.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T02:15:00Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "You've hit your session limit · resets 2:10am (UTC)",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt.timeIntervalSince1970, event.timeIntervalSince1970 - 300, accuracy: 1)
        XCTAssertTrue(result.isElapsed(relativeTo: event))
    }

    func testResetPicksNearestOccurrenceAcrossMidnight() throws {
        let event = ISO8601DateFormatter().date(from: "2026-07-10T23:50:00Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "resets 0:30am (UTC)",
            eventTimestamp: event
        ))
        // Nearest 00:30 occurrence is 40 minutes in the future (next day).
        XCTAssertEqual(result.resetAt.timeIntervalSince1970, event.timeIntervalSince1970 + 2_400, accuracy: 1)
        XCTAssertFalse(result.isElapsed(relativeTo: event))
    }

    func testResetHandlesPMandNoHint() throws {
        let event = ISO8601DateFormatter().date(from: "2026-07-10T10:00:00Z")!
        let pm = try XCTUnwrap(TranscriptResetParser.parse(messageText: "resets 9:00pm (UTC)", eventTimestamp: event))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.hour, from: pm.resetAt), 21)
        XCTAssertNil(TranscriptResetParser.parse(messageText: "no reset hint here", eventTimestamp: event))
    }

    // MARK: - Discovery

    func testDiscoversExecutableBlockedSession() async throws {
        let cwd = tempDir.path // an existing directory ⇒ executable
        try writeTranscript(lines: [
            rateLimit("You've hit your session limit · resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(candidate.isExecutable)
        XCTAssertEqual(candidate.workingDirectory, cwd)
        XCTAssertEqual(candidate.reason, .sessionLimit)
    }

    func testSubagentTranscriptsExcluded() async throws {
        let cwd = tempDir.path
        try writeTranscript(session: "subagent", lines: [
            rateLimit("You've hit your session limit · resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd, sidechain: true)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testDeadWorktreeRecordsSkipNotExecutable() async throws {
        let deadCwd = tempDir.appendingPathComponent("deleted-worktree").path
        try writeTranscript(lines: [
            rateLimit("You've hit your session limit · resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: deadCwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertFalse(candidate.isExecutable)
        XCTAssertEqual(candidate.skipReason, .missingWorkingDirectory)
    }

    func testMissingCwdMetadataRecordsUnknownSkip() async throws {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T02:00:00.000Z",
            "isApiErrorMessage": true,
            "apiErrorStatus": 429,
            "sessionId": "s",
            "message": ["role": "assistant", "content": [["type": "text", "text": "session limit, resets 2:10am (UTC)"]]]
        ]
        try writeTranscript(lines: [jsonLine(object)])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.skipReason, .unknownWorkingDirectory)
    }

    func testDuplicateSessionKeepsNewestBlock() async throws {
        let cwd = tempDir.path
        try writeTranscript(lines: [
            rateLimit("session limit resets 1:00am (UTC)", timestamp: "2026-07-10T01:00:00.000Z", cwd: cwd),
            assistantText("progress", timestamp: "2026-07-10T01:30:00.000Z", cwd: cwd),
            rateLimit("session limit resets 3:00am (UTC)", timestamp: "2026-07-10T02:30:00.000Z", cwd: cwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
        let blockedAt = try XCTUnwrap(candidates.first?.blockedAt)
        XCTAssertEqual(
            blockedAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-07-10T02:30:00Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testAccountScopedDiscoveryNeverReadsOtherAccount() async throws {
        let cwd = tempDir.path
        try writeTranscript(account: "acct", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        try writeTranscript(account: "other", session: "session-b", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir("acct"), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
    }

    func testActiveSessionProducesNoCandidate() async throws {
        let cwd = tempDir.path
        try writeTranscript(lines: [
            assistantText("all good", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Replay ledger

    func testHandledFingerprintNotRediscoveredAfterRelaunch() async throws {
        let cwd = tempDir.path
        try writeTranscript(lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let discovery = SessionDiscovery()

        let firstLedger = ReplayLedger(fileURL: ledgerURL)
        let first = await discovery.discover(configDirectory: accountConfigDir(), ledger: firstLedger)
        let fingerprint = try XCTUnwrap(first.first?.fingerprint)
        await firstLedger.record(fingerprint)

        // Simulate relaunch with a fresh ledger instance reading the same file.
        let secondLedger = ReplayLedger(fileURL: ledgerURL)
        let second = await discovery.discover(configDirectory: accountConfigDir(), ledger: secondLedger)
        XCTAssertEqual(second.first?.skipReason, .alreadyHandled)
        XCTAssertFalse(second.first?.isExecutable ?? true)
    }

    func testLedgerFingerprintIsStableForSameEvent() {
        let at = ISO8601DateFormatter().date(from: "2026-07-10T02:00:00Z")!
        let a = BlockFingerprint(sessionID: "s", blockedAt: at, reason: .sessionLimit)
        let b = BlockFingerprint(sessionID: "s", blockedAt: at, reason: .sessionLimit)
        let c = BlockFingerprint(sessionID: "s", blockedAt: at.addingTimeInterval(3_600), reason: .sessionLimit)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCorruptLedgerFailsSafeToEmpty() async throws {
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        try Data("not json".utf8).write(to: ledgerURL)
        let ledger = ReplayLedger(fileURL: ledgerURL)
        let fingerprint = BlockFingerprint(sessionID: "s", blockedAt: Date(), reason: .sessionLimit)
        let contained = await ledger.contains(fingerprint)
        XCTAssertFalse(contained)
    }
}
