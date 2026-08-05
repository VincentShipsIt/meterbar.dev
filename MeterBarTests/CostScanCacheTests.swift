import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Incremental per-file scan cache (issue: repeat scans re-parsing immutable
/// transcripts). Every test here exists to defend one claim: a warm scan must
/// produce the *same numbers* as a cold one. Speed is worthless if the totals
/// drift, so the assertions compare the full `TokenCost` + `DailyTokenUsage`
/// shape rather than a headline figure.
final class CostScanCacheTests: XCTestCase {
    private var tempDirectory: URL!

    /// Fixed instant so day bucketing is reproducible regardless of when CI runs.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Cold vs warm equality

    func testWarmClaudeScanMatchesColdScanExactly() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-3, hour: 9), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 1_200, output: 340, cacheCreation: 900, cacheRead: 4_000),
            claudeLine(at: day(-3, hour: 18), id: "m2", request: "r2", model: "claude-sonnet-4-5",
                       input: 80, output: 12, cacheCreation: 0, cacheRead: 640),
            claudeLine(at: day(-1, hour: 11), id: "m3", request: "r3", model: "claude-opus-4-6",
                       input: 55, output: 900, cacheCreation: 120, cacheRead: 0, oneHour: 100)
        ])
        try writeClaudeTranscript(root: root, project: "-Users-me-beta", name: "b.jsonl", lines: [
            claudeLine(at: day(-2, hour: 14), id: "m4", request: "r4", model: "claude-haiku-4-5",
                       input: 10, output: 3, cacheCreation: 0, cacheRead: 0, isSidechain: true)
        ])

        let cutoff = dayStart(-7)
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff)

        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cache.misses, 2)
        XCTAssertEqual(cache.hits, 0)

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 2)
        XCTAssertEqual(warmCache.misses, 0)

        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    func testWarmCodexScanMatchesColdScanExactly() throws {
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-4, hour: 8), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTokenLine(at: day(-4, hour: 8), id: "conv-1", input: 900, output: 120,
                           cached: 400, reasoning: 60),
            codexTurnContextLine(at: day(-4, hour: 9), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-4, hour: 9), id: "conv-1", input: 1_500, output: 300,
                           cached: 1_100, reasoning: 200),
            codexTokenLine(at: day(-1, hour: 9), id: "conv-1", input: 20, output: 5,
                           cached: 0, reasoning: 0)
        ])
        try writeCodexRollout(name: "rollout-2.jsonl", lines: [
            codexSessionMetaLine(at: day(-2, hour: 10), id: "conv-2", originator: "codex_vscode",
                                 cwd: "/Users/me/beta"),
            codexTurnContextLine(at: day(-2, hour: 10), model: "gpt-5.6-terra"),
            codexTokenLine(at: day(-2, hour: 10), id: "conv-2", input: 42, output: 7,
                           cached: 3, reasoning: 1)
        ], in: directory)

        let cutoff = dayStart(-7)
        var cold = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &cold)

        let cache = CostScanCache()
        var seed = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &seed, cache: cache)
        XCTAssertEqual(cache.misses, 2)

        let warmCache = CostScanCache(previous: cache.snapshot())
        var warm = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warm, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 2)
        XCTAssertEqual(warmCache.misses, 0)

        assertSameCodexCost(cold, warm)
    }

    // MARK: - Invalidation

    func testTouchingModificationTimeInvalidatesOnlyThatEntry() throws {
        let root = try makeClaudeRoot()
        let first = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])
        try writeClaudeTranscript(root: root, project: "-Users-me-beta", name: "b.jsonl", lines: [
            claudeLine(at: day(-2), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 200, output: 40, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)

        // Same bytes, newer mtime — the content stamp must not vouch for it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_123)],
            ofItemAtPath: first.path
        )

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 1, "the untouched transcript should still be served from cache")
        XCTAssertEqual(warmCache.misses, 1, "the touched transcript must be re-parsed")
        XCTAssertEqual(warm.lifetime.input, 300)
    }

    func testChangingFileSizeInvalidatesThatEntry() throws {
        let root = try makeClaudeRoot()
        let url = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        let stamp = try XCTUnwrap(CostScanFileStamp.read(at: url))

        // Rewrite with different token counts but restore the old mtime, so only
        // the size differs. A size-blind stamp would serve the stale totals.
        try [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100_000, output: 20, cacheCreation: 0, cacheRead: 0)
        ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: stamp.modified)],
            ofItemAtPath: url.path
        )

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        XCTAssertEqual(warmCache.misses, 1)
        XCTAssertEqual(warm.lifetime.input, 100_000)
    }

    func testAppendingToClaudeTranscriptPicksUpNewEvents() throws {
        let root = try makeClaudeRoot()
        let url = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)

        let appended = [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0),
            claudeLine(at: day(0, hour: 1), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 7, output: 3, cacheCreation: 0, cacheRead: 0)
        ].joined(separator: "\n")
        try appended.write(to: url, atomically: true, encoding: .utf8)

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff)

        XCTAssertEqual(warm.lifetime.input, 107)
        XCTAssertEqual(warm.lifetime.output, 23)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    func testAppendingToCodexRolloutPicksUpNewEvents() throws {
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-3), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-1", input: 100, output: 20, cached: 10, reasoning: 5)
        ])
        let url = directory.appendingPathComponent("rollout-1.jsonl")

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        var seed = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &seed, cache: cache)

        try [
            codexSessionMetaLine(at: day(-3), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-1", input: 100, output: 20, cached: 10, reasoning: 5),
            codexTokenLine(at: day(0, hour: 2), id: "conv-1", input: 9, output: 4, cached: 1, reasoning: 2)
        ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let warmCache = CostScanCache(previous: cache.snapshot())
        var warm = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warm, cache: warmCache)
        var cold = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &cold)

        XCTAssertEqual(warmCache.misses, 1)
        XCTAssertEqual(warm.lifetime.totals.input, 109)
        assertSameCodexCost(cold, warm)
    }

    func testDeletedFileDropsOutOfTotals() throws {
        let root = try makeClaudeRoot()
        let doomed = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])
        try writeClaudeTranscript(root: root, project: "-Users-me-beta", name: "b.jsonl", lines: [
            claudeLine(at: day(-2), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 200, output: 40, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        try FileManager.default.removeItem(at: doomed)

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)

        XCTAssertEqual(warm.lifetime.input, 200, "the deleted transcript must not linger in the totals")
        XCTAssertEqual(warm.lifetime.sessions, 1)
        XCTAssertNil(
            warmCache.snapshot().claude.first { $0.path == doomed.path },
            "a file that vanished should also drop out of the persisted cache"
        )
    }

    func testDeletedCodexRolloutDropsOutOfTotals() throws {
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-3), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-1", input: 100, output: 20, cached: 10, reasoning: 5)
        ])
        try writeCodexRollout(name: "rollout-2.jsonl", lines: [
            codexSessionMetaLine(at: day(-3), id: "conv-2", originator: "codex_cli_rs",
                                 cwd: "/Users/me/beta"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-2", input: 400, output: 80, cached: 40, reasoning: 20)
        ], in: directory)

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        var seed = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &seed, cache: cache)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("rollout-1.jsonl"))

        let warmCache = CostScanCache(previous: cache.snapshot())
        var warm = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warm, cache: warmCache)

        XCTAssertEqual(warm.lifetime.totals.input, 400)
        XCTAssertEqual(warmCache.snapshot().codex.count, 1)
    }

    // MARK: - The cutoff moves

    func testRollingClockForwardADayReusesCacheAndKeepsPeriodTotalsCorrect() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-5), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 1_000, output: 100, cacheCreation: 0, cacheRead: 0),
            claudeLine(at: day(-4), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 200, output: 20, cacheCreation: 0, cacheRead: 0),
            claudeLine(at: day(-3), id: "m3", request: "r3", model: "claude-sonnet-4-5",
                       input: 30, output: 3, cacheCreation: 0, cacheRead: 0)
        ])

        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: dayStart(-5), cache: cache)

        // Same corpus, cutoff advanced one day: the period must shed day -5
        // without touching the file again.
        let laterCutoff = dayStart(-4)
        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: laterCutoff, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 1)
        XCTAssertEqual(warmCache.misses, 0, "a moved cutoff must not force a re-parse")

        XCTAssertEqual(warm.period.input, 230)
        XCTAssertEqual(warm.lifetime.input, 1_230)

        let cold = ClaudeCostScanner.scanProjectRoot(root, since: laterCutoff)
        assertSameClaudeCost(cold, warm, cutoff: laterCutoff)
    }

    func testRollingClockForwardADayReusesCodexCache() throws {
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-5), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-5), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-5), id: "conv-1", input: 1_000, output: 100, cached: 0, reasoning: 0),
            codexTokenLine(at: day(-4), id: "conv-1", input: 200, output: 20, cached: 0, reasoning: 0),
            codexTokenLine(at: day(-3), id: "conv-1", input: 30, output: 3, cached: 0, reasoning: 0)
        ])

        let cache = CostScanCache()
        var seed = CodexCostScanner.scanWindows(cutoff: dayStart(-5))
        CodexCostScanner.scanRollouts(directory: directory, windows: &seed, cache: cache)

        let laterCutoff = dayStart(-4)
        let warmCache = CostScanCache(previous: cache.snapshot())
        var warm = CodexCostScanner.scanWindows(cutoff: laterCutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warm, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 1)
        XCTAssertEqual(warmCache.misses, 0)
        XCTAssertEqual(warm.period.totals.input, 230)
        XCTAssertEqual(warm.lifetime.totals.input, 1_230)

        var cold = CodexCostScanner.scanWindows(cutoff: laterCutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &cold)
        assertSameCodexCost(cold, warm)
    }

    func testNonDayAlignedCutoffBypassesClaudeCacheAndStaysCorrect() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2, hour: 3), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 10, cacheCreation: 0, cacheRead: 0),
            claudeLine(at: day(-2, hour: 20), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 7, output: 1, cacheCreation: 0, cacheRead: 0)
        ])

        // Mid-day cutoff: day buckets cannot express "half of day -2", so the
        // cache must decline to answer rather than round the period up.
        let cutoff = dayStart(-2).addingTimeInterval(12 * 3_600)
        let cache = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: dayStart(-7), cache: cache)

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 0, "a mid-day cutoff must not be served from day buckets")

        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff)
        XCTAssertEqual(warm.period.input, 7)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    // MARK: - Corruption and versioning

    func testCorruptCacheFileFallsBackToFullScanAndStaysCorrect() throws {
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        try Data("{ this is not json at all".utf8).write(to: cacheURL)

        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cache = CostScanCache.load(from: cacheURL)
        let cutoff = dayStart(-7)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff)

        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 1)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    func testVersionMismatchedCacheFallsBackToFullScanAndStaysCorrect() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        seeded.persist(to: cacheURL)
        XCTAssertNotNil(CostScanCacheStore.load(from: cacheURL))

        // Bump the stored version past what this build understands. A scanner
        // change must never be able to serve numbers computed by the old rules.
        var raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        raw["schemaVersion"] = CostScanCacheFile.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: raw).write(to: cacheURL)

        XCTAssertNil(CostScanCacheStore.load(from: cacheURL))
        let cache = CostScanCache.load(from: cacheURL)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff)

        XCTAssertEqual(cache.hits, 0)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    func testTruncatedEntryListSurvivesAsAPartialCacheNotAWrongTotal() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])
        try writeClaudeTranscript(root: root, project: "-Users-me-beta", name: "b.jsonl", lines: [
            claudeLine(at: day(-2), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 200, output: 40, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        let snapshot = seeded.snapshot()
        let partial = CostScanCacheFile(
            timeZoneIdentifier: snapshot.timeZoneIdentifier,
            claude: Array(snapshot.claude.prefix(1)),
            codex: []
        )

        let cache = CostScanCache(previous: partial)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
        XCTAssertEqual(warm.lifetime.input, 300)
    }

    func testTimeZoneChangeDiscardsClaudeEntriesButKeepsCodexRecords() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-3), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-1", input: 100, output: 20, cached: 10, reasoning: 5)
        ])

        let cutoff = dayStart(-7)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        var seed = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &seed, cache: seeded)

        let snapshot = seeded.snapshot()
        let travelled = CostScanCacheFile(
            timeZoneIdentifier: snapshot.timeZoneIdentifier == "UTC" ? "Asia/Tokyo" : "UTC",
            claude: snapshot.claude,
            codex: snapshot.codex
        )

        let cache = CostScanCache(previous: travelled)
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cache.misses, 1, "pre-bucketed Claude days are meaningless in a new zone")

        var warm = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warm, cache: cache)
        XCTAssertEqual(cache.hits, 1, "Codex records carry raw timestamps and re-bucket on replay")
        XCTAssertEqual(warm.lifetime.totals.input, 100)
    }

    // MARK: - Persistence and bounding

    func testCacheRoundTripsThroughDiskAndStillServesHits() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 1_234, output: 567, cacheCreation: 89, cacheRead: 10, oneHour: 40)
        ])
        let directory = try writeCodexRollout(name: "rollout-1.jsonl", lines: [
            codexSessionMetaLine(at: day(-3), id: "conv-1", originator: "codex_cli_rs",
                                 cwd: "/Users/me/alpha"),
            codexTurnContextLine(at: day(-3), model: "gpt-5.6-sol"),
            codexTokenLine(at: day(-3), id: "conv-1", input: 100, output: 20, cached: 10, reasoning: 5)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        let coldClaude = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        var coldCodex = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &coldCodex, cache: seeded)
        seeded.persist(to: cacheURL)

        let reloaded = CostScanCache.load(from: cacheURL)
        let warmClaude = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: reloaded)
        var warmCodex = CodexCostScanner.scanWindows(cutoff: cutoff)
        CodexCostScanner.scanRollouts(directory: directory, windows: &warmCodex, cache: reloaded)

        XCTAssertEqual(reloaded.hits, 2)
        XCTAssertEqual(reloaded.misses, 0)
        assertSameClaudeCost(coldClaude, warmClaude, cutoff: cutoff)
        assertSameCodexCost(coldCodex, warmCodex)

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testSnapshotEvictsLowestSavingsDensityEntriesWhenOverBudget() throws {
        // One entry per file, each holding two values-worth of digest. The
        // budget is set below the total so eviction has to choose.
        let entries = (0..<8).map { index in
            ClaudeCacheEntry(
                path: "/tmp/file-\(index).jsonl",
                stamp: CostScanFileStamp(size: Int64((index + 1) * 1_000), modified: 0, fileID: nil),
                digest: ClaudeTranscriptDigest(
                    projectID: "p",
                    models: ["claude-opus-4-6"],
                    origins: ["Main chat"],
                    days: [ClaudeTranscriptDigest.Day(
                        day: 0,
                        earliest: 0,
                        latest: 0,
                        buckets: [0, 0, 1, 1, 0, 0, 0, 1]
                    )]
                )
            )
        }
        let cache = CostScanCache()
        for entry in entries { cache.store(entry) }

        let bounded = cache.snapshot(maximumValues: 33, maximumEntries: 3)
        XCTAssertEqual(bounded.claude.count, 3)
        XCTAssertEqual(
            Set(bounded.claude.map(\.path)),
            ["/tmp/file-7.jsonl", "/tmp/file-6.jsonl", "/tmp/file-5.jsonl"],
            "the biggest files save the most re-parsing per stored value"
        )
    }

    func testDigestRefusesToCacheTranscriptsDayBucketsCannotReproduce() throws {
        let root = try makeClaudeRoot()
        // Same message/request key twice with different token counts: the cold
        // path keeps the last copy per window, which day buckets cannot model.
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0),
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 999, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cache = CostScanCache()
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cold.lifetime.input, 999)
        XCTAssertTrue(
            cache.snapshot().claude.isEmpty,
            "an ambiguous transcript must be re-parsed every time rather than cached wrong"
        )

        let warmCache = CostScanCache(previous: cache.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)
        XCTAssertEqual(warmCache.hits, 0)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    // MARK: - Stamp identity

    /// Both Claude Code and Codex write transcripts by rename-over-temp. That
    /// lands a *different* file behind the same path, and it can carry the same
    /// byte count and — on a coarse modification clock, or when the writer
    /// preserves timestamps — the same mtime. Size plus mtime would then serve
    /// the previous parse forever. The file number is what breaks the tie.
    func testAtomicReplaceWithIdenticalSizeAndModificationTimeIsNotServedFromCache() throws {
        let root = try makeClaudeRoot()
        let url = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        // A whole second, so it survives the `Date` → timespec → `Date` round
        // trip bit-exactly. Both the original and the replacement are pinned to
        // it, which is what leaves the file number as the only difference.
        let pinnedModification = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinnedModification], ofItemAtPath: url.path)

        let cutoff = dayStart(-7)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        XCTAssertEqual(seeded.misses, 1)

        let before = try XCTUnwrap(CostScanFileStamp.read(at: url))
        try XCTSkipIf(before.fileID == nil, "volume reports no file number; the identity check cannot apply here")

        // Widening `input` by one digit and narrowing `output` by one keeps the
        // line byte-for-byte the same length while changing what it says.
        let replacement = claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                                     input: 1_000, output: 2, cacheCreation: 0, cacheRead: 0)
        let staging = tempDirectory.appendingPathComponent("staging-\(UUID().uuidString).jsonl")
        try replacement.write(to: staging, atomically: false, encoding: .utf8)
        // Remove-then-move rather than `replaceItemAt`: this is exactly the
        // rename a CLI performs, and it deterministically lands a new inode.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: staging, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedModification],
            ofItemAtPath: url.path
        )

        let after = try XCTUnwrap(CostScanFileStamp.read(at: url))
        XCTAssertEqual(after.size, before.size, "fixture must keep the byte count identical")
        XCTAssertEqual(after.modified, before.modified, "fixture must restore the modification time")
        XCTAssertNotEqual(after.fileID, before.fileID, "rename-over-temp must land a new file number")

        let warmCache = CostScanCache(previous: seeded.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)

        XCTAssertEqual(warmCache.hits, 0, "a replaced file must never be served from cache")
        XCTAssertEqual(warmCache.misses, 1)
        XCTAssertEqual(warm.lifetime.input, 1_000, "the rescan must report the replacement's numbers")
        assertSameClaudeCost(ClaudeCostScanner.scanProjectRoot(root, since: cutoff), warm, cutoff: cutoff)
    }

    /// The whole point of the cache: a file nobody touched is never opened
    /// again. Proved by making the read physically impossible rather than by
    /// counting bytes — a hit that opened the file would fail outright.
    func testUnchangedFileIsServedWithoutReadingASingleByte() throws {
        let root = try makeClaudeRoot()
        let url = try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let seeded = CostScanCache()
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)

        // `chmod 000` moves ctime only — size, mtime, and inode are untouched,
        // so the stamp still matches and the entry stays eligible.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf(
            (try? FileHandle(forReadingFrom: url)) != nil,
            "file is still readable (running as root?); the no-read claim cannot be proved here"
        )

        let warmCache = CostScanCache(previous: seeded.snapshot())
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: warmCache)

        XCTAssertEqual(warmCache.hits, 1, "an unchanged file must be served from cache")
        XCTAssertEqual(warmCache.misses, 0)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    // MARK: - Whole-artifact invalidation

    /// A digest only means anything under the parsing and pricing rules that
    /// produced it. On a producer mismatch the artifact is discarded whole —
    /// partially trusting it would mix numbers computed under two rule sets.
    func testParserVersionMismatchDiscardsTheWholeCache() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])
        try writeClaudeTranscript(root: root, project: "-Users-me-beta", name: "b.jsonl", lines: [
            claudeLine(at: day(-2), id: "m2", request: "r2", model: "claude-opus-4-6",
                       input: 200, output: 40, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        seeded.persist(to: cacheURL)
        XCTAssertNotNil(CostScanCacheStore.load(from: cacheURL), "seeded artifact must load before it is edited")

        var raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        raw["parserVersion"] = CostScanValues.costCacheParserVersion + 1
        try JSONSerialization.data(withJSONObject: raw).write(to: cacheURL)

        XCTAssertNil(CostScanCacheStore.load(from: cacheURL), "a foreign producer must not be decoded into a cache")

        let cache = CostScanCache.load(from: cacheURL)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cache.hits, 0, "no entry may survive a producer mismatch")
        XCTAssertEqual(cache.misses, 2, "every file must be re-parsed")
        assertSameClaudeCost(ClaudeCostScanner.scanProjectRoot(root, since: cutoff), warm, cutoff: cutoff)
    }

    /// An artifact written under a different producer must also be unable to
    /// collide with this build's file in the first place.
    func testCacheFileNameCarriesTheSchemaVersion() {
        XCTAssertTrue(
            CostScanCacheStore.cacheFileName.contains("v\(CostScanCacheFile.currentSchemaVersion)"),
            "an old and a new binary must never write to the same path"
        )
    }

    /// Claude digests are pre-bucketed into *local* days, so a machine that
    /// moved time zone cannot reuse them. Covered in memory elsewhere; this
    /// pins the behaviour across the disk round trip, where the identifier has
    /// to survive encode and decode to have any effect.
    func testTimeZoneIdentifierMismatchOnDiskDiscardsCachedClaudeEntries() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        seeded.persist(to: cacheURL)

        var raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        let travelled = TimeZone.current.identifier == "UTC" ? "Asia/Tokyo" : "UTC"
        raw["timeZoneIdentifier"] = travelled
        try JSONSerialization.data(withJSONObject: raw).write(to: cacheURL)

        let cache = CostScanCache.load(from: cacheURL)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)

        XCTAssertEqual(cache.hits, 0, "day buckets built in another zone must not be reused")
        XCTAssertEqual(cache.misses, 1)
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    // MARK: - Artifact size guard

    /// `JSONDecoder` materialises roughly ten times the artifact's size in live
    /// objects, so an oversized file has to be refused on the stat, before a
    /// single byte is decoded. The artifact here is perfectly valid JSON: the
    /// only reason it must not load is its size.
    func testOversizedCacheArtifactIsRefusedBeforeDecodingAndRebuilds() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        let cold = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)
        seeded.persist(to: cacheURL)

        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertNotNil(
            CostScanCacheStore.load(from: cacheURL, maximumBytes: size),
            "an artifact exactly at the cap is still valid"
        )
        XCTAssertNil(
            CostScanCacheStore.load(from: cacheURL, maximumBytes: size - 1),
            "a valid artifact past the cap must still be refused"
        )

        let cache = CostScanCache.load(from: cacheURL, maximumBytes: size - 1)
        let warm = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: cache)
        XCTAssertEqual(cache.hits, 0, "a refused artifact must rebuild, not half-load")
        assertSameClaudeCost(cold, warm, cutoff: cutoff)
    }

    /// Writing an artifact the next launch would refuse buys nothing and costs
    /// disk, so the cap applies on the way out too.
    func testOversizedSnapshotIsNotWritten() throws {
        let root = try makeClaudeRoot()
        try writeClaudeTranscript(root: root, project: "-Users-me-alpha", name: "a.jsonl", lines: [
            claudeLine(at: day(-2), id: "m1", request: "r1", model: "claude-opus-4-6",
                       input: 100, output: 20, cacheCreation: 0, cacheRead: 0)
        ])

        let cutoff = dayStart(-7)
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let seeded = CostScanCache()
        _ = ClaudeCostScanner.scanProjectRoot(root, since: cutoff, cache: seeded)

        XCTAssertThrowsError(
            try CostScanCacheStore.save(seeded.snapshot(), to: cacheURL, maximumBytes: 8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "an over-cap artifact must not reach disk"
        )
    }

    /// Pins the documented budget. CodexBar hit multi-GiB decode spikes without
    /// one; 64 MB comfortably holds a ten-gigabyte corpus reduced to buckets.
    func testArtifactCapIsSixtyFourMegabytes() {
        XCTAssertEqual(CostScanCacheStore.maximumArtifactBytes, 64 * 1024 * 1024)
    }

    // MARK: - Comparison helpers

    private func assertSameClaudeCost(
        _ cold: ScanWindows<ClaudeSessionTotals>,
        _ warm: ScanWindows<ClaudeSessionTotals>,
        cutoff: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSameCost(
            ClaudeCostScanner.makeCost(from: cold.period, windowStart: cutoff),
            ClaudeCostScanner.makeCost(from: warm.period, windowStart: cutoff),
            label: "period", file: file, line: line
        )
        assertSameCost(
            ClaudeCostScanner.makeCost(from: cold.lifetime, windowStart: .distantPast),
            ClaudeCostScanner.makeCost(from: warm.lifetime, windowStart: .distantPast),
            label: "lifetime", file: file, line: line
        )
    }

    private func assertSameCodexCost(
        _ cold: ScanWindows<CodexScanContext>,
        _ warm: ScanWindows<CodexScanContext>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSameCost(
            CodexCostScanner.makeCost(from: cold.period),
            CodexCostScanner.makeCost(from: warm.period),
            label: "period", file: file, line: line
        )
        assertSameCost(
            CodexCostScanner.makeCost(from: cold.lifetime),
            CodexCostScanner.makeCost(from: warm.lifetime),
            label: "lifetime", file: file, line: line
        )
    }

    private func assertSameCost(
        _ cold: (TokenCost, [DailyTokenUsage])?,
        _ warm: (TokenCost, [DailyTokenUsage])?,
        label: String,
        file: StaticString,
        line: UInt
    ) {
        guard let cold, let warm else {
            XCTAssertEqual(cold == nil, warm == nil, "\(label): one window produced no cost", file: file, line: line)
            return
        }

        XCTAssertEqual(cold.0.inputTokens, warm.0.inputTokens, "\(label).input", file: file, line: line)
        XCTAssertEqual(cold.0.outputTokens, warm.0.outputTokens, "\(label).output", file: file, line: line)
        XCTAssertEqual(cold.0.cacheCreationTokens, warm.0.cacheCreationTokens,
                       "\(label).cacheCreation", file: file, line: line)
        XCTAssertEqual(cold.0.cacheReadTokens, warm.0.cacheReadTokens,
                       "\(label).cacheRead", file: file, line: line)
        XCTAssertEqual(cold.0.sessionCount, warm.0.sessionCount, "\(label).sessions", file: file, line: line)
        XCTAssertEqual(cold.0.estimatedCostUSD, warm.0.estimatedCostUSD, accuracy: 1e-9,
                       "\(label).cost", file: file, line: line)
        XCTAssertEqual(cold.0.periodStart, warm.0.periodStart, "\(label).periodStart", file: file, line: line)
        XCTAssertEqual(cold.0.periodEnd, warm.0.periodEnd, "\(label).periodEnd", file: file, line: line)

        assertSameBreakdowns(cold.0.modelBreakdowns, warm.0.modelBreakdowns,
                             label: "\(label).models", file: file, line: line)
        assertSameBreakdowns(cold.0.originBreakdowns, warm.0.originBreakdowns,
                             label: "\(label).origins", file: file, line: line)
        assertSameBreakdowns(cold.0.projectBreakdowns, warm.0.projectBreakdowns,
                             label: "\(label).projects", file: file, line: line)

        let coldDays = cold.1.sorted { $0.date < $1.date }
        let warmDays = warm.1.sorted { $0.date < $1.date }
        XCTAssertEqual(coldDays.count, warmDays.count, "\(label).dayCount", file: file, line: line)
        for (coldDay, warmDay) in zip(coldDays, warmDays) {
            XCTAssertEqual(coldDay.date, warmDay.date, "\(label).dayDate", file: file, line: line)
            XCTAssertEqual(coldDay.inputTokens, warmDay.inputTokens, "\(label).dayInput", file: file, line: line)
            XCTAssertEqual(coldDay.outputTokens, warmDay.outputTokens, "\(label).dayOutput", file: file, line: line)
            XCTAssertEqual(coldDay.cacheReadTokens, warmDay.cacheReadTokens,
                           "\(label).dayCacheRead", file: file, line: line)
            XCTAssertEqual(coldDay.estimatedCostUSD, warmDay.estimatedCostUSD, accuracy: 1e-9,
                           "\(label).dayCost", file: file, line: line)
            assertSameBreakdowns(coldDay.modelBreakdowns ?? [], warmDay.modelBreakdowns ?? [],
                                 label: "\(label).dayModels", file: file, line: line)
            assertSameBreakdowns(coldDay.projectBreakdowns ?? [], warmDay.projectBreakdowns ?? [],
                                 label: "\(label).dayProjects", file: file, line: line)
        }
    }

    private func assertSameBreakdowns(
        _ cold: [TokenUsageBreakdown],
        _ warm: [TokenUsageBreakdown],
        label: String,
        file: StaticString,
        line: UInt
    ) {
        let coldRows = cold.sorted { $0.name < $1.name }
        let warmRows = warm.sorted { $0.name < $1.name }
        XCTAssertEqual(coldRows.map(\.name), warmRows.map(\.name), "\(label).names", file: file, line: line)
        for (coldRow, warmRow) in zip(coldRows, warmRows) {
            XCTAssertEqual(coldRow.inputTokens, warmRow.inputTokens,
                           "\(label)[\(coldRow.name)].input", file: file, line: line)
            XCTAssertEqual(coldRow.outputTokens, warmRow.outputTokens,
                           "\(label)[\(coldRow.name)].output", file: file, line: line)
            XCTAssertEqual(coldRow.cacheCreationTokens, warmRow.cacheCreationTokens,
                           "\(label)[\(coldRow.name)].cacheCreation", file: file, line: line)
            XCTAssertEqual(coldRow.cacheReadTokens, warmRow.cacheReadTokens,
                           "\(label)[\(coldRow.name)].cacheRead", file: file, line: line)
            XCTAssertEqual(coldRow.sessionCount, warmRow.sessionCount,
                           "\(label)[\(coldRow.name)].sessions", file: file, line: line)
            XCTAssertEqual(coldRow.estimatedCostUSD, warmRow.estimatedCostUSD, accuracy: 1e-9,
                           "\(label)[\(coldRow.name)].cost", file: file, line: line)
            assertSameNestedBreakdowns(coldRow.modelBreakdowns, warmRow.modelBreakdowns,
                                       label: "\(label)[\(coldRow.name)].models", file: file, line: line)
        }
    }

    /// One level deep only — project rows nest models, and models nest nothing.
    private func assertSameNestedBreakdowns(
        _ cold: [TokenUsageBreakdown],
        _ warm: [TokenUsageBreakdown],
        label: String,
        file: StaticString,
        line: UInt
    ) {
        let coldRows = cold.sorted { $0.name < $1.name }
        let warmRows = warm.sorted { $0.name < $1.name }
        XCTAssertEqual(coldRows.map(\.name), warmRows.map(\.name), "\(label).names", file: file, line: line)
        for (coldRow, warmRow) in zip(coldRows, warmRows) {
            XCTAssertEqual(coldRow.inputTokens, warmRow.inputTokens,
                           "\(label)[\(coldRow.name)].input", file: file, line: line)
            XCTAssertEqual(coldRow.outputTokens, warmRow.outputTokens,
                           "\(label)[\(coldRow.name)].output", file: file, line: line)
            XCTAssertEqual(coldRow.estimatedCostUSD, warmRow.estimatedCostUSD, accuracy: 1e-9,
                           "\(label)[\(coldRow.name)].cost", file: file, line: line)
        }
    }

    // MARK: - Fixture helpers

    private func dayStart(_ offset: Int) -> Date {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
            return calendar.startOfDay(for: now)
        }
        return start
    }

    private func day(_ offset: Int, hour: Int = 12) -> Date {
        dayStart(offset).addingTimeInterval(TimeInterval(hour) * 3_600)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func iso(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private func makeClaudeRoot() throws -> URL {
        let root = tempDirectory.appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeClaudeTranscript(
        root: URL,
        project: String,
        name: String,
        lines: [String]
    ) throws -> URL {
        let directory = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // swiftlint:disable:next function_parameter_count
    private func claudeLine(
        at timestamp: Date,
        id: String,
        request: String,
        model: String,
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        oneHour: Int = 0,
        isSidechain: Bool = false
    ) -> String {
        """
        {"timestamp": "\(iso(timestamp))", "requestId": "\(request)", \
        "isSidechain": \(isSidechain), "message": {"id": "\(id)", "model": "\(model)", \
        "usage": {"input_tokens": \(input), "output_tokens": \(output), \
        "cache_creation_input_tokens": \(cacheCreation), "cache_read_input_tokens": \(cacheRead), \
        "cache_creation": {"ephemeral_1h_input_tokens": \(oneHour)}}}}
        """
    }

    @discardableResult
    private func writeCodexRollout(
        name: String,
        lines: [String],
        in existing: URL? = nil
    ) throws -> URL {
        let directory: URL
        if let existing {
            directory = existing
        } else {
            directory = tempDirectory
                .appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("archived_sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return directory
    }

    private func codexSessionMetaLine(
        at timestamp: Date,
        id: String,
        originator: String,
        cwd: String
    ) -> String {
        """
        {"timestamp": "\(iso(timestamp))", "type": "session_meta", "payload": \
        {"id": "\(id)", "originator": "\(originator)", "cli_version": "0.0.0", "cwd": "\(cwd)"}}
        """
    }

    private func codexTurnContextLine(at timestamp: Date, model: String) -> String {
        """
        {"timestamp": "\(iso(timestamp))", "type": "turn_context", "payload": \
        {"model": "\(model)", "effort": "high", "summary": "auto"}}
        """
    }

    // swiftlint:disable:next function_parameter_count
    private func codexTokenLine(
        at timestamp: Date,
        id: String,
        input: Int,
        output: Int,
        cached: Int,
        reasoning: Int
    ) -> String {
        """
        {"timestamp": "\(iso(timestamp))", "type": "event_msg", "payload": {"type": "token_count", \
        "rate_limits": {"conversation_id": "\(id)"}, "info": {"last_token_usage": \
        {"input_tokens": \(input), "output_tokens": \(output), \
        "cached_input_tokens": \(cached), "reasoning_output_tokens": \(reasoning)}}}}
        """
    }
}
