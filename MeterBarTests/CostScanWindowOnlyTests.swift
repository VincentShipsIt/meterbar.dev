import XCTest
@testable import MeterBar
import MeterBarShared

/// Window-only cost scan: list by mtime / filename, never publish lifetime,
/// and never kick a refresh just because lifetime is missing.
final class CostScanWindowOnlyTests: XCTestCase {
    func testListingSkipsFilesOlderThanModifiedSince() throws {
        let root = try makeCorpusDirectory()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "fresh.jsonl", bytes: 20, modified: now)
        try writeCorpusFile(
            in: root,
            name: "stale.jsonl",
            bytes: 9_999,
            modified: now.addingTimeInterval(-CostScanSession.listingSlack - 60)
        )

        let listing = CostScanCorpus.listing(in: root, modifiedSince: now.addingTimeInterval(-60))

        XCTAssertEqual(listing.files.map(\.url.lastPathComponent), ["fresh.jsonl"])
        XCTAssertTrue(listing.isComplete)
        XCTAssertEqual(listing.files.first?.size, 20)
    }

    func testListingKeepsTheWalkCompleteWhenItFiltersByAge() throws {
        let root = try makeCorpusDirectory()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "old.jsonl", bytes: 10, modified: now.addingTimeInterval(-10_000))

        let listing = CostScanCorpus.listing(in: root, modifiedSince: now)

        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertTrue(listing.isComplete)
    }

    func testListingFiltersToNamedTranscripts() throws {
        let root = try makeCorpusDirectory()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "updates.jsonl", bytes: 40, modified: now)
        try writeCorpusFile(in: root, name: "messages.jsonl", bytes: 80, modified: now)

        let listing = CostScanCorpus.listing(in: root, fileNames: ["updates.jsonl"])

        XCTAssertEqual(listing.files.map(\.url.lastPathComponent), ["updates.jsonl"])
        XCTAssertEqual(listing.files.first?.size, 40)
    }

    func testListingCutoffIsCutoffMinusSlack() {
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)

        XCTAssertEqual(
            session.listingCutoff,
            cutoff.addingTimeInterval(-CostScanSession.listingSlack)
        )
        XCTAssertEqual(CostScanSession.listingSlack, 36 * 60 * 60)
    }

    func testMakeScanDoesNotPublishLifetime() {
        let scan = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [],
            claudeAccounts: [],
            grokAccounts: [],
            session: CostScanSession(cutoff: Date(), options: .unlimited)
        )

        XCTAssertNil(scan.summary.lifetime)
    }

    func testMissingLifetimeDoesNotTriggerABackgroundRefresh() {
        let today = Date()
        let summary = CostSummary(
            costs: [
                TokenCost(
                    provider: .claudeCode,
                    inputTokens: 100,
                    outputTokens: 10,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1,
                    sessionCount: 1,
                    periodStart: today,
                    periodEnd: today
                )
            ],
            totalCostUSD: 1,
            totalTokens: 110,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: Calendar.current.startOfDay(for: today),
                    provider: .claudeCode,
                    inputTokens: 100,
                    outputTokens: 10,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 1,
                    modelBreakdowns: [],
                    projectBreakdowns: [],
                    sessionBreakdowns: []
                )
            ],
            hourlyUsage: [],
            lifetime: nil
        )

        XCTAssertFalse(
            CostTracker.needsBackgroundRefresh(
                summary: summary,
                lastScanDate: today,
                enabledServices: [.claudeCode],
                days: 30,
                now: today
            )
        )
    }

    func testNilSummaryStillRefreshesWhenALogProviderIsEnabled() {
        XCTAssertTrue(
            CostTracker.needsBackgroundRefresh(
                summary: nil,
                lastScanDate: nil,
                enabledServices: [.claudeCode],
                days: 30
            )
        )
        XCTAssertFalse(
            CostTracker.needsBackgroundRefresh(
                summary: nil,
                lastScanDate: nil,
                enabledServices: [.cursor],
                days: 30
            )
        )
    }

    func testProgressWarnsOnceTheWindowedCorpusIsAGigabyte() {
        var progress = CostScanProgress(windowDays: 30)
        XCTAssertEqual(progress.statusText, "Listing session files…")
        XCTAssertFalse(progress.isLargeCorpus)

        progress.listedFiles = 12
        progress.listedBytes = 180 * 1_000_000
        progress.processedFiles = 4
        XCTAssertTrue(progress.statusText.hasPrefix("Scanning 4 of 12 files · "))
        XCTAssertTrue(progress.statusText.contains(CostScanProgress.formatBytes(180 * 1_000_000)))
        XCTAssertFalse(progress.isLargeCorpus)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 4.0 / 12.0, accuracy: 0.000_001)

        progress.listedBytes = CostScanProgress.largeCorpusBytes
        XCTAssertTrue(progress.isLargeCorpus)
        XCTAssertTrue(progress.detailText.contains("Older archives are not scanned"))
    }

    func testUnreadFilesAreNotCountedAsProcessed() throws {
        let root = try makeCorpusDirectory()
        let newest = try writeClaudeTranscript(
            in: root,
            name: "newest.jsonl",
            messageID: "new",
            modifiedAgo: 0
        )
        try writeClaudeTranscript(
            in: root,
            name: "oldest.jsonl",
            messageID: "old",
            modifiedAgo: 60
        )
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let budget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: try fileSize(newest),
            wallClock: nil
        )
        let session = CostScanSession(cutoff: cutoff, options: budget)

        _ = ClaudeCostScanner.scanRoots([root], session: session)
        let progress = session.progress(windowDays: 30)

        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(progress.listedFiles, 2)
        XCTAssertEqual(progress.processedFiles, 1)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 0.5, accuracy: 0.000_001)
        XCTAssertFalse(progress.isComplete)
    }

    func testListingEmitsProgressBeforeAnyFileIsProcessed() throws {
        let root = try makeCorpusDirectory()
        try writeClaudeTranscript(in: root, name: "a.jsonl", messageID: "a", modifiedAgo: 0)
        try writeClaudeTranscript(in: root, name: "b.jsonl", messageID: "b", modifiedAgo: 1)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let seen = CostScanProgressLog()
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)
        session.observeProgress(windowDays: 30, seen.append)

        _ = ClaudeCostScanner.scanRoots([root], session: session)

        let first = try XCTUnwrap(seen.snapshots.first)
        XCTAssertEqual(first.listedFiles, 2)
        XCTAssertEqual(first.processedFiles, 0)
        XCTAssertGreaterThan(first.listedBytes, 0)
        XCTAssertFalse(first.isComplete)

        let last = try XCTUnwrap(seen.snapshots.last)
        XCTAssertEqual(last.processedFiles, 2)
        XCTAssertTrue(last.isComplete)
    }

    // MARK: - Fixtures

    private func makeCorpusDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanWindowOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeCorpusFile(in root: URL, name: String, bytes: Int, modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: UInt8(ascii: "x"), count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @discardableResult
    private func writeClaudeTranscript(
        in root: URL,
        name: String,
        messageID: String,
        modifiedAgo: TimeInterval
    ) throws -> URL {
        let line = """
        {"timestamp": "2026-07-01T10:00:00.000Z", "requestId": "req_\(messageID)", \
        "message": {"id": "msg_\(messageID)", "model": "claude-sonnet-4-5", \
        "usage": {"input_tokens": 100, "output_tokens": 10, \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
        let url = root.appendingPathComponent(name)
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-modifiedAgo)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}

/// Lock-guarded so a progress handler running on the scan queue can record
/// snapshots without tripping Sendable checking.
private final class CostScanProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CostScanProgress] = []

    var snapshots: [CostScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ progress: CostScanProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }
}
