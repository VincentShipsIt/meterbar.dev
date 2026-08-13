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
                    projectBreakdowns: []
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
}
