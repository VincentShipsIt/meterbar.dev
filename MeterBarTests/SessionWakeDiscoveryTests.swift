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

    // MARK: - Reset parser: explicit month/day (weekly limits)

    func testMonthDayResetForm() throws {
        // Weekly limits state a calendar date, not just a clock time.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "You've hit your weekly limit · resets Jul 15 at 10pm (Europe/Malta)",
            eventTimestamp: event
        ))
        // 10pm Malta (UTC+2 in July) on Jul 15 == 20:00Z.
        XCTAssertEqual(result.resetAt, ISO8601DateFormatter().date(from: "2026-07-15T20:00:00Z"))
        XCTAssertEqual(result.timeZoneIdentifier, "Europe/Malta")
    }

    func testMonthDayResetRollsToNextYearWhenBeforeEvent() throws {
        // A December block whose reset reads "Jan 2" is next January, not this
        // year's already-elapsed January (December → January window).
        let event = ISO8601DateFormatter().date(from: "2026-12-30T12:00:00Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "You've hit your weekly limit · resets Jan 2 at 9am (UTC)",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt, ISO8601DateFormatter().date(from: "2027-01-02T09:00:00Z"))
    }

    func testSlightlyElapsedMonthDayResetStaysPastInsteadOfRollingAYear() throws {
        // Display rounding or a timezone fallback can put the resolved reset
        // minutes before the event; that must read as "already elapsed,
        // re-check now" — not as next year's reset.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T09:05:00Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "You've hit your weekly limit · resets Jul 10 at 9am (UTC)",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt, ISO8601DateFormatter().date(from: "2026-07-10T09:00:00Z"))
    }

    func testStatedYearIsAuthoritativeEvenWhenPast() throws {
        // An explicit year never rolls forward, even if it is long elapsed.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "You've hit your weekly limit · resets Jan 2, 2026 at 9am (UTC)",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt, ISO8601DateFormatter().date(from: "2026-01-02T09:00:00Z"))
    }

    func testImpossibleDayOfMonthIsRejected() {
        // Calendar would silently normalize "Jul 32" to Aug 1; the parser must
        // refuse instead of inventing a date the message never stated.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        XCTAssertNil(TranscriptResetParser.parse(
            messageText: "You've hit your weekly limit · resets Jul 32 at 9am (UTC)",
            eventTimestamp: event
        ))
    }

    func testWeeklyMonthDayMessageClassifiesBlockedWithReset() throws {
        let cwd = tempDir.path
        let lines = [
            rateLimit(
                "You've hit your weekly limit · resets Jul 15 at 10pm (Europe/Malta)",
                timestamp: "2026-07-10T04:00:00.000Z",
                cwd: cwd
            )
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        guard case let .blocked(reason, _, resetHint) = summary.state else {
            return XCTFail("Expected blocked, got \(summary.state)")
        }
        XCTAssertEqual(reason, .weeklyLimit)
        XCTAssertEqual(resetHint?.resetAt, ISO8601DateFormatter().date(from: "2026-07-15T20:00:00Z"))
    }

    // MARK: - Tail read: multi-byte UTF-8 boundary

    func testTailReadSplittingMultibyteCharStillDiscoversBlock() async throws {
        let cwd = tempDir.path
        let block = rateLimit(
            "session limit resets 2:10am (UTC)",
            timestamp: "2026-07-10T02:00:00.000Z",
            cwd: cwd
        )
        // Prefix ends with a 2-byte character ("é") and the tail window is sized
        // so the read begins on its continuation byte. A failable
        // String(data:encoding:) would reject the whole buffer and drop the
        // transcript's decisive event; lossy decoding must keep the block line.
        let content = "Xé\n" + block
        let dir = tempDir
            .appendingPathComponent("acct")
            .appendingPathComponent("projects")
            .appendingPathComponent("-Users-me-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("session-a.jsonl"), atomically: true, encoding: .utf8)

        let discovery = SessionDiscovery(
            configuration: .init(maxTailBytes: block.utf8.count + 2)
        )
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.reason, .sessionLimit)
    }

    // MARK: - Classifier: sidechain lines only exclude all-subagent transcripts

    func testSidechainLinesAreIgnoredForClassification() {
        // A mainline session that finished after spawning a subagent (whose
        // transcript tail is a sidechain block) is active, not a subagent.
        let cwd = tempDir.path
        let lines = [
            assistantText("Resumed and finished the task.", timestamp: "2026-07-10T03:00:00.000Z", cwd: cwd),
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T04:00:00.000Z", cwd: cwd, sidechain: true)
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        XCTAssertFalse(summary.isSidechain, "a mainline session with subagent lines is not a subagent transcript")
        if case .active = summary.state {} else {
            XCTFail("A sidechain block must not classify the mainline session, got \(summary.state)")
        }
    }

    func testAllSidechainTranscriptIsFlaggedSubagent() {
        let cwd = tempDir.path
        let lines = [
            assistantText("subagent working", timestamp: "2026-07-10T03:00:00.000Z", cwd: cwd, sidechain: true),
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T04:00:00.000Z", cwd: cwd, sidechain: true)
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: lines)
        XCTAssertTrue(summary.isSidechain)
        if case .indeterminate = summary.state {} else {
            XCTFail("An all-sidechain transcript has no mainline terminal state, got \(summary.state)")
        }
    }

    // MARK: - Deterministic dedupe & read-only preview

    func testDuplicateSessionTieBreaksOnLexicographicallyFirstPath() async throws {
        let cwd = tempDir.path
        // Same session and same block instant across two project directories:
        // the winner must be deterministic regardless of enumeration order.
        try writeTranscript(project: "-proj-b", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        try writeTranscript(project: "-proj-a", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(
            candidates.first?.transcriptPath.contains("-proj-a") == true,
            "equal-timestamp duplicates must tie-break on the lexicographically first path"
        )
    }

    func testDiscoveryPerformsZeroFilesystemMutations() async throws {
        let cwd = tempDir.path
        try writeTranscript(lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")

        let before = try snapshot(of: tempDir)
        let discovery = SessionDiscovery()
        _ = await discovery.discover(configDirectory: accountConfigDir(), ledger: ReplayLedger(fileURL: ledgerURL))
        let after = try snapshot(of: tempDir)

        XCTAssertEqual(before, after, "discovery is a preview and must not create, modify, or delete any file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ledgerURL.path),
            "discovery must not write the replay ledger"
        )
    }

    // MARK: - Legacy pipe-epoch reset marker (Shape B transcripts)

    func testLegacyPipeEpochYieldsExactResetInstant() throws {
        // "usage limit reached|1752130800" states the reset as a unix epoch —
        // an exact instant, not a wall-clock hint needing nearest-occurrence
        // resolution.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "Claude AI usage limit reached|1752130800",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt, Date(timeIntervalSince1970: 1_752_130_800))
        XCTAssertNil(result.timeZoneIdentifier)
    }

    func testLegacyEpochWinsOverResetsClauseInSameMessage() throws {
        // If both forms ever co-occur, the exact epoch is authoritative.
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        let result = try XCTUnwrap(TranscriptResetParser.parse(
            messageText: "Claude AI usage limit reached|1752130800 · resets 7:30am (Europe/Malta)",
            eventTimestamp: event
        ))
        XCTAssertEqual(result.resetAt, Date(timeIntervalSince1970: 1_752_130_800))
    }

    func testLegacyEpochWithImplausibleDigitCountIsNotParsed() {
        let event = ISO8601DateFormatter().date(from: "2026-07-10T04:14:15Z")!
        // 8 digits (1970s) and 13 digits (milliseconds) are not epoch seconds.
        XCTAssertNil(TranscriptResetParser.parse(
            messageText: "usage limit reached|17521308",
            eventTimestamp: event
        ))
        XCTAssertNil(TranscriptResetParser.parse(
            messageText: "usage limit reached|1752130800123",
            eventTimestamp: event
        ))
    }

    func testLegacyMarkerLineWithoutApiErrorFlagClassifiesBlocked() {
        // Shape B (legacy) transcripts carry no isApiErrorMessage/apiErrorStatus
        // fields at all — the pipe-epoch marker alone must classify as blocked.
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T04:14:15.000Z",
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "Claude AI usage limit reached|1752130800"]]
            ]
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: [jsonLine(object)])
        guard case let .blocked(_, _, resetHint) = summary.state else {
            return XCTFail("Expected blocked from legacy marker, got \(summary.state)")
        }
        XCTAssertEqual(resetHint?.resetAt, Date(timeIntervalSince1970: 1_752_130_800))
    }

    func testLegacyMarkerQuotedInAssistantProseDoesNotBlock() {
        // An assistant message QUOTING the marker (prose, code, summaries of
        // MeterBar development sessions...) is not a synthetic limit line —
        // blocking anchors to the whole trimmed text being exactly the marker.
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T04:14:15.000Z",
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": [
                "role": "assistant",
                "content": "I added a fixture using \"Claude AI usage limit reached|1752130800\" to the tests."
            ]
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: [jsonLine(object)])
        if case .blocked = summary.state {
            XCTFail("Assistant prose quoting the legacy marker must not classify as blocked")
        }
    }

    func testExactLegacyMarkerLineWithPrefixBlocks() {
        // The genuine synthetic line — nothing but the marker (optionally
        // prefixed "Claude AI") — still classifies as blocked.
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T04:14:15.000Z",
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": [
                "role": "assistant",
                "content": "Claude AI usage limit reached|1752130800"
            ]
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: [jsonLine(object)])
        guard case .blocked = summary.state else {
            return XCTFail("Exact legacy marker line must classify as blocked")
        }
    }

    func testLegacyMarkerQuotedInUserLineDoesNotBlock() {
        // Only an assistant line is a synthetic limit message; a user merely
        // quoting the marker text proves nothing about quota.
        let object: [String: Any] = [
            "type": "user",
            "timestamp": "2026-07-10T04:14:15.000Z",
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": [
                "role": "user",
                "content": "why did it say usage limit reached|1752130800 earlier?"
            ]
        ]
        let summary = TranscriptClassifier.classify(sessionID: "s", lines: [jsonLine(object)])
        if case .blocked = summary.state {
            XCTFail("A user line quoting the legacy marker must not classify as blocked")
        }
    }

    func testLegacyBlockedTranscriptIsDiscovered() async throws {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-07-10T04:14:15.000Z",
            "cwd": tempDir.path,
            "sessionId": "s",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "Claude AI usage limit reached|1752130800"]]
            ]
        ]
        try writeTranscript(lines: [jsonLine(object)])
        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.resetHint?.resetAt, Date(timeIntervalSince1970: 1_752_130_800))
    }

    // MARK: - Enumeration bounds

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testTranscriptsOlderThanMaxAgeAreSkipped() async throws {
        let cwd = tempDir.path
        let now = Date()
        let fresh = try writeTranscript(session: "fresh", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        ])
        let stale = try writeTranscript(session: "stale", lines: [
            rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-09T02:00:00.000Z", cwd: cwd)
        ])
        try setModificationDate(now.addingTimeInterval(-3_600), at: fresh)
        try setModificationDate(now.addingTimeInterval(-15 * 24 * 3_600), at: stale)

        let discovery = SessionDiscovery(configuration: .init(maxTranscriptAge: 14 * 24 * 3_600))
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger, now: now)

        XCTAssertEqual(candidates.count, 1)
        // /var vs /private/var: compare with symlinks resolved.
        XCTAssertEqual(
            candidates.first.map { URL(fileURLWithPath: $0.transcriptPath).resolvingSymlinksInPath().path },
            fresh.resolvingSymlinksInPath().path
        )
    }

    func testTranscriptCapScansNewestFirst() async throws {
        let cwd = tempDir.path
        let now = Date()
        // Three distinct sessions; the oldest transcript must fall off the cap.
        // Each transcript resolves its own sessionId from the JSONL line.
        var urls: [String: URL] = [:]
        for (index, name) in ["old", "mid", "new"].enumerated() {
            let object: [String: Any] = [
                "type": "assistant",
                "timestamp": "2026-07-10T02:00:00.000Z",
                "isApiErrorMessage": true,
                "apiErrorStatus": 429,
                "cwd": cwd,
                "sessionId": name,
                "message": ["role": "assistant", "content": [["type": "text", "text": "session limit resets 2:10am (UTC)"]]]
            ]
            let url = try writeTranscript(session: name, lines: [jsonLine(object)])
            try setModificationDate(now.addingTimeInterval(TimeInterval(-3_600 * (3 - index))), at: url)
            urls[name] = url
        }

        let discovery = SessionDiscovery(configuration: .init(maxTranscripts: 2))
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger, now: now)

        let sessionIDs = Set(candidates.map(\.sessionID))
        XCTAssertEqual(sessionIDs, ["mid", "new"], "the cap must keep the newest transcripts, dropping the oldest")
    }

    func testSubagentsDirectoryComponentIsSkipped() async throws {
        let cwd = tempDir.path
        let dir = tempDir
            .appendingPathComponent("acct")
            .appendingPathComponent("projects")
            .appendingPathComponent("-Users-me-proj")
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd)
        try line.write(to: dir.appendingPathComponent("child.jsonl"), atomically: true, encoding: .utf8)

        let discovery = SessionDiscovery()
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertTrue(candidates.isEmpty, "transcripts under a subagents/ directory are never resume targets")
    }

    func testOnlyTailBytesAreReadFromLargeTranscripts() async throws {
        let cwd = tempDir.path
        // A huge prefix of non-decisive noise; the decisive block sits at the tail.
        var lines = (0..<50).map { index in
            jsonLine([
                "type": "user",
                "timestamp": "2026-07-10T01:00:00.000Z",
                "cwd": cwd,
                "sessionId": "s",
                "message": ["role": "user", "content": "noise line \(index) padding padding padding padding"]
            ])
        }
        lines.append(rateLimit("session limit resets 2:10am (UTC)", timestamp: "2026-07-10T02:00:00.000Z", cwd: cwd))
        try writeTranscript(lines: lines)

        let discovery = SessionDiscovery(configuration: .init(maxTailBytes: 4_096))
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("ledger.json"))
        let candidates = await discovery.discover(configDirectory: accountConfigDir(), ledger: ledger)
        XCTAssertEqual(candidates.count, 1, "a bounded tail read must still find the decisive tail event")
    }

    // MARK: - Replay ledger capacity

    private func fingerprint(_ index: Int) -> BlockFingerprint {
        BlockFingerprint(
            sessionID: "session-\(index)",
            blockedAt: Date(timeIntervalSince1970: TimeInterval(1_752_000_000 + index)),
            reason: .sessionLimit
        )
    }

    func testLedgerPrunesOldestBeyondCapacity() async throws {
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let ledger = ReplayLedger(fileURL: ledgerURL, maxEntries: 3)
        for index in 0..<5 {
            await ledger.record(fingerprint(index))
        }

        let count = await ledger.count()
        XCTAssertEqual(count, 3, "the ledger must never exceed its capacity")
        let contains0 = await ledger.contains(fingerprint(0))
        let contains1 = await ledger.contains(fingerprint(1))
        XCTAssertFalse(contains0, "the oldest entries are pruned first")
        XCTAssertFalse(contains1, "the oldest entries are pruned first")
        for index in 2..<5 {
            let contained = await ledger.contains(fingerprint(index))
            XCTAssertTrue(contained, "recent entry \(index) must survive pruning")
        }
    }

    func testLedgerPruningOrderSurvivesRelaunch() async throws {
        let ledgerURL = tempDir.appendingPathComponent("ledger.json")
        let first = ReplayLedger(fileURL: ledgerURL, maxEntries: 3)
        for index in 0..<3 {
            await first.record(fingerprint(index))
        }

        // A fresh instance (relaunch) must keep pruning oldest-first, not
        // restart its notion of age.
        let relaunched = ReplayLedger(fileURL: ledgerURL, maxEntries: 3)
        await relaunched.record(fingerprint(3))

        let dropped = await relaunched.contains(fingerprint(0))
        XCTAssertFalse(dropped, "after relaunch the persisted oldest entry is still pruned first")
        for index in 1..<4 {
            let contained = await relaunched.contains(fingerprint(index))
            XCTAssertTrue(contained)
        }
        let count = await relaunched.count()
        XCTAssertEqual(count, 3)
    }

    /// Recursive path → "size|modification-date" map used to prove read-only behavior.
    private func snapshot(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = values.contentModificationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            result[url.path] = "\(values.fileSize ?? -1)|\(stamp)"
        }
        return result
    }
}
