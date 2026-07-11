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
