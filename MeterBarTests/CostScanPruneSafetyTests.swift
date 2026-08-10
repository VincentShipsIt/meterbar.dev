import Foundation
import XCTest
@testable import MeterBar

/// What the cost scan is allowed to conclude from *not* seeing a transcript.
///
/// `CostScanSession.retain` treats an absent cache key as a deleted file and
/// drops its record. That is correct only when the walk that produced the key
/// set actually saw the whole corpus: a walk that skipped a subtree it could
/// not read, or an entry it could not stat, has no evidence of deletion at all.
/// Pruning against that partial view discards a live transcript's resumable
/// offset — the refresh undercounts, and the next one pays for a full re-read.
final class CostScanPruneSafetyTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Corpus listing

    func testListingOfAReadableTreeIsComplete() throws {
        let root = try makeTemporaryDirectory(named: "CostScanPruneComplete")
        try writeTranscript(at: root.appendingPathComponent("a.jsonl"))
        try writeTranscript(at: root.appendingPathComponent("nested/b.jsonl"))

        let listing = CostScanCorpus.listing(in: root)

        XCTAssertTrue(listing.isComplete)
        XCTAssertTrue(listing.unreadableKeys.isEmpty)
        XCTAssertEqual(
            Set(listing.files.map(\.url.lastPathComponent)),
            ["a.jsonl", "b.jsonl"]
        )
    }

    /// A subtree the walk cannot descend into is the realistic shape of this
    /// bug: the transcripts under it still exist, they are simply unlisted.
    func testListingOfATreeWithAnUnreadableDirectoryIsIncomplete() throws {
        let root = try makeTemporaryDirectory(named: "CostScanPruneLockedDir")
        try writeTranscript(at: root.appendingPathComponent("visible.jsonl"))
        try lockDirectory(at: root.appendingPathComponent("locked", isDirectory: true), holding: "hidden.jsonl")

        let listing = CostScanCorpus.listing(in: root)

        XCTAssertFalse(listing.isComplete)
        XCTAssertEqual(listing.files.map(\.url.lastPathComponent), ["visible.jsonl"])
    }

    /// A `.jsonl` the walk lists but cannot stamp. `EINTR` and friends make this
    /// a transient property of one lookup, not of the file, so it is reported
    /// rather than dropped — the caller keeps its cache record and tries again.
    func testListingReportsEntriesItCannotStamp() throws {
        let root = try makeTemporaryDirectory(named: "CostScanPruneStatFailure")
        let unstampable = root.appendingPathComponent("racy.jsonl")
        try writeTranscript(at: unstampable)
        try writeTranscript(at: root.appendingPathComponent("stable.jsonl"))

        let listing = CostScanCorpus.listing(in: root) { url in
            url.lastPathComponent == "racy.jsonl" ? nil : CostScanFileStamp.read(at: url)
        }

        XCTAssertEqual(listing.files.map(\.url.lastPathComponent), ["stable.jsonl"])
        XCTAssertEqual(listing.unreadableKeys, [CostScanCorpus.cacheKey(for: unstampable)])
        // The tree itself was walked end to end. Only one lookup inside it
        // failed, and the grace period covers exactly that key.
        XCTAssertTrue(listing.isComplete)
    }

    /// A directory named `x.jsonl`, or a symlink to nowhere, is a definite
    /// answer: it is not a transcript, and never was one. Reporting it as
    /// unreadable would keep a phantom cache key alive forever.
    func testListingDoesNotReportNonRegularEntriesAsUnreadable() throws {
        let root = try makeTemporaryDirectory(named: "CostScanPruneNonRegular")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dangling.jsonl").path,
            withDestinationPath: root.appendingPathComponent("missing.jsonl").path
        )

        let listing = CostScanCorpus.listing(in: root)

        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertTrue(listing.unreadableKeys.isEmpty)
        XCTAssertTrue(listing.isComplete)
    }

    // MARK: - Coverage

    func testCoverageRetainsScannedAndUnreadableKeysAndFoldsCompleteness() {
        var coverage = CostScanCorpusCoverage()
        XCTAssertTrue(coverage.isComplete)

        coverage.add(CostScanCorpusListing(files: [], unreadableKeys: ["/tmp/a.jsonl"], isComplete: true))
        XCTAssertTrue(coverage.keep("/tmp/b.jsonl"))
        // Overlapping roots hand the same transcript over twice; the second
        // sighting is not a second file to scan.
        XCTAssertFalse(coverage.keep("/tmp/b.jsonl"))
        XCTAssertEqual(coverage.retainedKeys, ["/tmp/a.jsonl", "/tmp/b.jsonl"])
        XCTAssertTrue(coverage.isComplete)

        coverage.add(CostScanCorpusListing(files: [], unreadableKeys: [], isComplete: false))
        XCTAssertFalse(coverage.isComplete)
    }

    /// An unreadable key must not make the file look already-scanned: one root
    /// failing to stat a path says nothing about the root that reads it fine.
    func testUnreadableKeysDoNotSuppressScanningTheSamePathFromAnotherRoot() {
        var coverage = CostScanCorpusCoverage()
        coverage.add(CostScanCorpusListing(files: [], unreadableKeys: ["/tmp/a.jsonl"], isComplete: true))

        XCTAssertTrue(coverage.keep("/tmp/a.jsonl"))
    }

    // MARK: - Claude

    func testClaudeKeepsCachedRecordsWhenPartOfTheCorpusCouldNotBeListed() throws {
        let root = try makeTemporaryDirectory(named: "ClaudePruneProjects")
        try writeTranscript(at: root.appendingPathComponent("project/visible.jsonl"), line: claudeEventLine())
        let hidden = try lockDirectory(
            at: root.appendingPathComponent("locked", isDirectory: true),
            holding: "hidden.jsonl"
        )
        let session = makeSession()
        session.setClaudeRecord(makeClaudeRecord(offset: 4_096), for: CostScanCorpus.cacheKey(for: hidden))
        // A transcript that really is gone. An incomplete walk cannot tell it
        // apart from `hidden.jsonl`, so it survives too — one refresh of stale
        // totals is recoverable, a discarded offset is not.
        session.setClaudeRecord(makeClaudeRecord(), for: "/tmp/deleted-\(UUID().uuidString).jsonl")

        _ = ClaudeCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(session.claude.records.count, 3)
        XCTAssertEqual(session.claude.records[CostScanCorpus.cacheKey(for: hidden)]?.offset, 4_096)
    }

    /// The other half of the contract: a walk that saw everything still prunes,
    /// or the cache would grow without bound.
    func testClaudeStillPrunesDeletedTranscriptsWhenTheWalkIsComplete() throws {
        let root = try makeTemporaryDirectory(named: "ClaudePruneComplete")
        let visible = root.appendingPathComponent("project/visible.jsonl")
        try writeTranscript(at: visible, line: claudeEventLine())
        let session = makeSession()
        session.setClaudeRecord(makeClaudeRecord(), for: "/tmp/deleted-\(UUID().uuidString).jsonl")

        _ = ClaudeCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(
            Set(session.claude.records.keys),
            [CostScanCorpus.cacheKey(for: visible)]
        )
    }

    // MARK: - Codex

    func testCodexKeepsCachedRecordsWhenPartOfTheCorpusCouldNotBeListed() throws {
        let root = try makeTemporaryDirectory(named: "CodexPruneRollouts")
        try writeTranscript(at: root.appendingPathComponent("visible.jsonl"), line: codexTokenLine())
        let hidden = try lockDirectory(
            at: root.appendingPathComponent("locked", isDirectory: true),
            holding: "hidden.jsonl"
        )
        let session = makeSession()
        session.setCodexRecord(makeCodexRecord(offset: 4_096), for: CostScanCorpus.cacheKey(for: hidden))

        _ = CodexCostScanner.scanRollouts(directories: [root], session: session)

        XCTAssertEqual(session.codex.records[CostScanCorpus.cacheKey(for: hidden)]?.offset, 4_096)
    }

    func testCodexStillPrunesDeletedRolloutsWhenTheWalkIsComplete() throws {
        let root = try makeTemporaryDirectory(named: "CodexPruneComplete")
        let visible = root.appendingPathComponent("visible.jsonl")
        try writeTranscript(at: visible, line: codexTokenLine())
        let session = makeSession()
        session.setCodexRecord(makeCodexRecord(), for: "/tmp/deleted-\(UUID().uuidString).jsonl")

        _ = CodexCostScanner.scanRollouts(directories: [root], session: session)

        XCTAssertEqual(Set(session.codex.records.keys), [CostScanCorpus.cacheKey(for: visible)])
    }

    // MARK: - Grok

    func testGrokKeepsCachedRecordsWhenPartOfTheCorpusCouldNotBeListed() throws {
        let root = try makeTemporaryDirectory(named: "GrokPruneSessions")
        try writeTranscript(at: root.appendingPathComponent("session-a/updates.jsonl"), line: grokTurnLine())
        let hidden = try lockDirectory(
            at: root.appendingPathComponent("locked", isDirectory: true),
            holding: "updates.jsonl"
        )
        let session = makeSession()
        session.setGrokRecord(makeGrokRecord(offset: 4_096), for: CostScanCorpus.cacheKey(for: hidden))

        _ = GrokCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(session.grok.records[CostScanCorpus.cacheKey(for: hidden)]?.offset, 4_096)
    }

    func testGrokStillPrunesDeletedSessionsWhenTheWalkIsComplete() throws {
        let root = try makeTemporaryDirectory(named: "GrokPruneComplete")
        let visible = root.appendingPathComponent("session-a/updates.jsonl")
        try writeTranscript(at: visible, line: grokTurnLine())
        let session = makeSession()
        session.setGrokRecord(makeGrokRecord(), for: "/tmp/deleted-\(UUID().uuidString).jsonl")

        _ = GrokCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(Set(session.grok.records.keys), [CostScanCorpus.cacheKey(for: visible)])
    }
}

// MARK: - Fixtures

extension CostScanPruneSafetyTests {
    private func makeSession() -> CostScanSession {
        CostScanSession(cutoff: cutoff, options: .unlimited)
    }

    private func makeClaudeRecord(offset: UInt64 = 0) -> CostScanFileRecord<ClaudeFileTotals> {
        makeRecord(offset: offset, payload: ClaudeFileTotals())
    }

    private func makeCodexRecord(offset: UInt64 = 0) -> CostScanFileRecord<CodexFileTotals> {
        makeRecord(offset: offset, payload: CodexFileTotals(cutoff: cutoff))
    }

    private func makeGrokRecord(offset: UInt64 = 0) -> CostScanFileRecord<GrokFileTotals> {
        makeRecord(offset: offset, payload: GrokFileTotals(cutoff: cutoff))
    }

    private func makeRecord<Payload>(offset: UInt64, payload: Payload) -> CostScanFileRecord<Payload> {
        CostScanFileRecord(
            offset: offset,
            stamp: CostScanFileStamp(size: Int(offset), modified: cutoff.timeIntervalSince1970, fileID: 42),
            cutoff: cutoff,
            isComplete: true,
            payload: payload
        )
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeTranscript(at url: URL, line: String = "{}") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A subdirectory holding a transcript that the walk can neither list nor
    /// stat. Restored to searchable on teardown so the temp tree can be removed.
    ///
    /// - Returns: the URL of the transcript now hidden behind it.
    @discardableResult
    private func lockDirectory(at directory: URL, holding name: String) throws -> URL {
        let transcript = directory.appendingPathComponent(name)
        try writeTranscript(at: transcript)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        return transcript
    }

    private func claudeEventLine() -> String {
        """
        {"timestamp": "2026-06-15T10:00:00.000Z", "requestId": "req_1", \
        "message": {"id": "msg_1", "model": "claude-sonnet-4-5", \
        "usage": {"input_tokens": 100, "output_tokens": 50, \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    private func codexTokenLine() -> String {
        """
        {"timestamp": "2026-06-15T10:00:00Z", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "conv-1"}, \
        "info": {"model": "gpt-5.5", "last_token_usage": \
        {"input_tokens": 1000, "output_tokens": 500, \
        "cached_input_tokens": 200, "reasoning_output_tokens": 50}}}}
        """
    }

    private func grokTurnLine() -> String {
        """
        {"timestamp":"2026-06-15T10:00:00.000Z","method":"session/update",\
        "params":{"sessionId":"019fafec-972e-7413-8cbd-01647988c8f9",\
        "update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn",\
        "usage":{"inputTokens":100,"outputTokens":10,"totalTokens":110,\
        "cachedReadTokens":0,"reasoningTokens":0,"modelCalls":1,\
        "apiDurationMs":1234,"costUsdTicks":1000000,"numTurns":1}}}}
        """
    }
}
