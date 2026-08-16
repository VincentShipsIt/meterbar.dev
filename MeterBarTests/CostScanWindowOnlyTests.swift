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
        XCTAssertEqual(try XCTUnwrap(last.fraction), 1.0, accuracy: 0.000_001)
    }

    func testFractionNeverReachesOneWhileTheScanIsIncomplete() {
        var progress = CostScanProgress(windowDays: 30)
        progress.listedFiles = 1
        progress.processedFiles = 1
        progress.isComplete = false

        XCTAssertLessThan(try XCTUnwrap(progress.fraction), 1)

        progress.listedFiles = 4
        progress.processedFiles = 4
        XCTAssertLessThan(try XCTUnwrap(progress.fraction), 1)

        progress.isComplete = true
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 1)
    }

    /// A single file the byte budget cannot finish is not processed. Counting
    /// it would make the banner say "Scanning 1 of 1 files" while the only
    /// file is still open, and force the bar back to 0% via the incomplete cap.
    func testPartialReadDoesNotReportOneOfOneAsProcessed() throws {
        let root = try makeCorpusDirectory()
        let first = claudeEventLine(messageID: "a")
        let second = claudeEventLine(messageID: "b")
        try writeClaudeLines(in: root, name: "partial.jsonl", lines: [first, second], modifiedAgo: 0)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let budget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: first.utf8.count + 1,
            wallClock: nil
        )
        let session = CostScanSession(cutoff: cutoff, options: budget)

        let windows = ClaudeCostScanner.scanRoots([root], session: session)
        let progress = session.progress(windowDays: 30)

        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(progress.listedFiles, 1)
        XCTAssertEqual(progress.processedFiles, 0)
        XCTAssertFalse(progress.isComplete)
        XCTAssertFalse(progress.statusText.contains("1 of 1"))
        XCTAssertTrue(progress.statusText.hasPrefix("Scanning 1 files"))
        XCTAssertLessThan(try XCTUnwrap(progress.fraction), 1)
        XCTAssertEqual(windows.period.input, 100)
    }

    /// Cached incomplete records still return a payload when the next slice
    /// has no budget left. Counting those as processed reports 100% on a
    /// refresh that read nothing new.
    func testDeferredCachedFileDoesNotCountAsProcessed() throws {
        let root = try makeCorpusDirectory()
        let first = claudeEventLine(messageID: "a")
        let second = claudeEventLine(messageID: "b")
        try writeClaudeLines(in: root, name: "partial.jsonl", lines: [first, second], modifiedAgo: 0)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()
        let firstBudget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: first.utf8.count + 1,
            wallClock: nil
        )

        let firstSlice = CostScanSession(cutoff: cutoff, options: firstBudget, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: firstSlice)
        XCTAssertEqual(firstSlice.persist(), .persisted)
        XCTAssertFalse(firstSlice.isComplete)

        let emptyBudget = CostScanBudgetOptions(
            maxBytesPerFile: .max,
            maxNewBytesPerRefresh: 0,
            wallClock: nil
        )
        let secondSlice = CostScanSession(cutoff: cutoff, options: emptyBudget, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: secondSlice)
        let progress = secondSlice.progress(windowDays: 30)

        XCTAssertFalse(secondSlice.isComplete)
        XCTAssertEqual(progress.listedFiles, 1)
        XCTAssertEqual(progress.processedFiles, 0)
        XCTAssertFalse(progress.isComplete)
        XCTAssertLessThan(try XCTUnwrap(progress.fraction), 1)
    }

    func testWarmCacheHitsCountAsProcessedOnACompletedSlice() throws {
        let root = try makeCorpusDirectory()
        try writeClaudeTranscript(in: root, name: "a.jsonl", messageID: "a", modifiedAgo: 0)
        try writeClaudeTranscript(in: root, name: "b.jsonl", messageID: "b", modifiedAgo: 1)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let store = try makeScanCacheStore()

        let first = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist(), .persisted)
        XCTAssertTrue(first.isComplete)

        let second = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        _ = ClaudeCostScanner.scanRoots([root], session: second)
        let progress = second.progress(windowDays: 30)

        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(progress.listedFiles, 2)
        XCTAssertEqual(progress.processedFiles, 2)
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 1.0, accuracy: 0.000_001)
    }

    /// `CostTracker.makeCostSummary` drives one slice through `makeScan` plus
    /// `observeProgress`. A completed single-slice refresh must publish the
    /// listing (files + bytes, processed == 0) before the finished snapshot.
    func testSingleSliceRefreshPublishesListingBeforeCompletion() throws {
        let root = try makeCorpusDirectory()
        try writeClaudeTranscript(in: root, name: "a.jsonl", messageID: "a", modifiedAgo: 0)
        try writeClaudeTranscript(in: root, name: "b.jsonl", messageID: "b", modifiedAgo: 1)
        let cutoff = try XCTUnwrap(FlexibleISO8601.date(from: "2026-06-01T00:00:00Z"))
        let seen = CostScanProgressLog()
        let session = CostScanSession(cutoff: cutoff, options: .unlimited)
        session.observeProgress(windowDays: 30, seen.append)

        let scan = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [.claude],
            claudeAccounts: [],
            grokAccounts: [],
            session: session,
            claudeProjectRoots: [root]
        )

        XCTAssertTrue(scan.isComplete)
        XCTAssertNil(scan.summary.lifetime)

        let first = try XCTUnwrap(seen.snapshots.first)
        XCTAssertEqual(first.listedFiles, 2)
        XCTAssertEqual(first.processedFiles, 0)
        XCTAssertGreaterThan(first.listedBytes, 0)
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(try XCTUnwrap(first.fraction), 0, accuracy: 0.000_001)

        let last = try XCTUnwrap(seen.snapshots.last)
        XCTAssertEqual(last.processedFiles, 2)
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(try XCTUnwrap(last.fraction), 1.0, accuracy: 0.000_001)
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
        try writeClaudeLines(
            in: root,
            name: name,
            lines: [claudeEventLine(messageID: messageID)],
            modifiedAgo: modifiedAgo
        )
    }

    @discardableResult
    private func writeClaudeLines(
        in root: URL,
        name: String,
        lines: [String],
        modifiedAgo: TimeInterval
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-modifiedAgo)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func claudeEventLine(messageID: String) -> String {
        """
        {"timestamp": "2026-07-01T10:00:00.000Z", "requestId": "req_\(messageID)", \
        "message": {"id": "msg_\(messageID)", "model": "claude-sonnet-4-5", \
        "usage": {"input_tokens": 100, "output_tokens": 10, \
        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
        """
    }

    private func makeScanCacheStore() throws -> CostScanCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanWindowCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CostScanCacheStore(directory: directory)
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
