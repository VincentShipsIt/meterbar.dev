import Foundation
import XCTest
@testable import MeterBar

/// Opt-in wall-clock benchmark for the incremental scan cache.
///
/// Reads the machine's **real** `~/.claude*` and `~/.codex` corpora, so it is
/// gated the same way `APIIntegrationTests` is: skipped unless explicitly asked
/// for. A developer box holds gigabytes of archived transcripts and CI holds
/// none, so the numbers are meaningless anywhere but the machine that produced
/// them, and the runtime (minutes, cold) has no business in the default suite.
///
/// Enable with:
/// ```
/// METERBAR_SCAN_BENCHMARK=1 swift test --filter CostScanCacheBenchmarkTests
/// ```
///
/// Set `METERBAR_SCAN_BENCHMARK_OUTPUT=/path/to/result.json` to also write the
/// measurements to disk; otherwise they go to the unified log only, since the
/// repo forbids `print`.
final class CostScanCacheBenchmarkTests: XCTestCase {
    private static let environmentKey = "METERBAR_SCAN_BENCHMARK"
    private static let outputKey = "METERBAR_SCAN_BENCHMARK_OUTPUT"

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.environmentKey] == "1",
            """
            Scan benchmarks are opt-in. They read the real Claude and Codex \
            transcript corpora on this machine. Re-run with \(Self.environmentKey)=1 to include them.
            """
        )
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostScanCacheBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    /// Cold (no cache) versus warm (cache written by a previous identical run),
    /// both through the production entry point the refresh loop calls.
    func testWarmSummaryMatchesColdSummaryAndIsFaster() throws {
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        let accounts = [ClaudeCodeAccount.defaultAccount]

        let cold = Self.measure { Self.makeSummary(accounts: accounts, cacheURL: nil) }
        // Not measured: this is the run that pays for the cache the warm run reads.
        let seeded = Self.measure { Self.makeSummary(accounts: accounts, cacheURL: cacheURL) }
        let warm = Self.measure { Self.makeSummary(accounts: accounts, cacheURL: cacheURL) }

        // The whole point of the exercise: faster, and identical to the byte.
        Self.assertSameSummary(cold.value, warm.value)

        let counted = Self.countCacheOutcomes(accounts: accounts, cacheURL: cacheURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)

        let report = BenchmarkReport(
            coldSeconds: cold.seconds,
            seedSeconds: seeded.seconds,
            warmSeconds: warm.seconds,
            speedup: warm.seconds > 0 ? cold.seconds / warm.seconds : 0,
            cacheHits: counted.hits,
            cacheMisses: counted.misses,
            cacheFileBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            totalCostUSD: cold.value.totalCostUSD,
            lifetimeCostUSD: cold.value.lifetime?.totalCostUSD ?? 0
        )
        try Self.publish(report)

        XCTAssertLessThan(warm.seconds, cold.seconds, "a warm scan that is not faster is a cache doing nothing")
    }

    // MARK: - Helpers

    private static func makeSummary(accounts: [ClaudeCodeAccount], cacheURL: URL?) -> CostSummary {
        CostSummaryBuilder.makeSummary(
            days: 30,
            includeClaudeCode: true,
            includeCodexCli: true,
            claudeAccounts: accounts,
            scanCacheURL: cacheURL
        )
    }

    private static func measure<Value>(_ body: () -> Value) -> (value: Value, seconds: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return (value, Double(elapsed) / 1_000_000_000)
    }

    /// `makeSummary` owns its cache instance, so hit and miss counts come from a
    /// separate pass over the same corpus with the same on-disk cache.
    private static func countCacheOutcomes(
        accounts: [ClaudeCodeAccount],
        cacheURL: URL
    ) -> (hits: Int, misses: Int) {
        let cutoff = CostWindow.start(days: 30)
        let cache = CostScanCache.load(from: cacheURL)
        _ = ClaudeCostScanner.scanSessions(since: cutoff, claudeAccounts: accounts, cache: cache)
        _ = CodexCostScanner.scanSessions(since: cutoff, cache: cache)
        return (cache.hits, cache.misses)
    }

    private static func assertSameSummary(
        _ cold: CostSummary,
        _ warm: CostSummary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(cold.totalTokens, warm.totalTokens, "totalTokens", file: file, line: line)
        XCTAssertEqual(cold.totalCostUSD, warm.totalCostUSD, accuracy: 1e-9, "totalCostUSD", file: file, line: line)
        XCTAssertEqual(cold.costs.map(\.provider), warm.costs.map(\.provider), "cost rows", file: file, line: line)

        for (coldRow, warmRow) in zip(cold.costs, warm.costs) {
            let label = coldRow.provider.rawValue
            XCTAssertEqual(coldRow.inputTokens, warmRow.inputTokens, "\(label).input", file: file, line: line)
            XCTAssertEqual(coldRow.outputTokens, warmRow.outputTokens, "\(label).output", file: file, line: line)
            XCTAssertEqual(coldRow.cacheCreationTokens, warmRow.cacheCreationTokens,
                           "\(label).cacheCreation", file: file, line: line)
            XCTAssertEqual(coldRow.cacheReadTokens, warmRow.cacheReadTokens,
                           "\(label).cacheRead", file: file, line: line)
            XCTAssertEqual(coldRow.sessionCount, warmRow.sessionCount, "\(label).sessions", file: file, line: line)
            XCTAssertEqual(coldRow.estimatedCostUSD, warmRow.estimatedCostUSD, accuracy: 1e-9,
                           "\(label).cost", file: file, line: line)
            XCTAssertEqual(coldRow.periodStart, warmRow.periodStart, "\(label).start", file: file, line: line)
            XCTAssertEqual(coldRow.periodEnd, warmRow.periodEnd, "\(label).end", file: file, line: line)
            Self.assertSameBreakdowns(coldRow.modelBreakdowns, warmRow.modelBreakdowns,
                                      label: "\(label).models", file: file, line: line)
            Self.assertSameBreakdowns(coldRow.originBreakdowns, warmRow.originBreakdowns,
                                      label: "\(label).origins", file: file, line: line)
            Self.assertSameBreakdowns(coldRow.projectBreakdowns, warmRow.projectBreakdowns,
                                      label: "\(label).projects", file: file, line: line)
        }

        XCTAssertEqual(cold.dailyUsage.map(\.id), warm.dailyUsage.map(\.id), "daily rows", file: file, line: line)
        for (coldDay, warmDay) in zip(cold.dailyUsage, warm.dailyUsage) {
            XCTAssertEqual(coldDay.inputTokens, warmDay.inputTokens, "\(coldDay.id).input", file: file, line: line)
            XCTAssertEqual(coldDay.outputTokens, warmDay.outputTokens, "\(coldDay.id).output", file: file, line: line)
            XCTAssertEqual(coldDay.cacheReadTokens, warmDay.cacheReadTokens,
                           "\(coldDay.id).cacheRead", file: file, line: line)
            XCTAssertEqual(coldDay.estimatedCostUSD, warmDay.estimatedCostUSD, accuracy: 1e-9,
                           "\(coldDay.id).cost", file: file, line: line)
            Self.assertSameBreakdowns(coldDay.modelBreakdowns ?? [], warmDay.modelBreakdowns ?? [],
                                      label: "\(coldDay.id).models", file: file, line: line)
            Self.assertSameBreakdowns(coldDay.projectBreakdowns ?? [], warmDay.projectBreakdowns ?? [],
                                      label: "\(coldDay.id).projects", file: file, line: line)
        }

        XCTAssertEqual(cold.lifetime?.providers.map(\.provider), warm.lifetime?.providers.map(\.provider),
                       "lifetime providers", file: file, line: line)
        XCTAssertEqual(cold.lifetime?.totalCostUSD ?? 0, warm.lifetime?.totalCostUSD ?? 0, accuracy: 1e-9,
                       "lifetime cost", file: file, line: line)
    }

    private static func assertSameBreakdowns(
        _ cold: [TokenUsageBreakdown],
        _ warm: [TokenUsageBreakdown],
        label: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(cold.map(\.name), warm.map(\.name), "\(label).names", file: file, line: line)
        for (coldRow, warmRow) in zip(cold, warm) {
            XCTAssertEqual(coldRow.inputTokens, warmRow.inputTokens,
                           "\(label).\(coldRow.name).input", file: file, line: line)
            XCTAssertEqual(coldRow.outputTokens, warmRow.outputTokens,
                           "\(label).\(coldRow.name).output", file: file, line: line)
            XCTAssertEqual(coldRow.cacheCreationTokens, warmRow.cacheCreationTokens,
                           "\(label).\(coldRow.name).cacheCreation", file: file, line: line)
            XCTAssertEqual(coldRow.cacheReadTokens, warmRow.cacheReadTokens,
                           "\(label).\(coldRow.name).cacheRead", file: file, line: line)
            XCTAssertEqual(coldRow.sessionCount, warmRow.sessionCount,
                           "\(label).\(coldRow.name).sessions", file: file, line: line)
            XCTAssertEqual(coldRow.estimatedCostUSD, warmRow.estimatedCostUSD, accuracy: 1e-9,
                           "\(label).\(coldRow.name).cost", file: file, line: line)
        }
    }

    private static func publish(_ report: BenchmarkReport) throws {
        AppLog.cost.notice(
            """
            cost scan benchmark: cold=\(report.coldSeconds, privacy: .public)s \
            seed=\(report.seedSeconds, privacy: .public)s \
            warm=\(report.warmSeconds, privacy: .public)s \
            speedup=\(report.speedup, privacy: .public)x \
            hits=\(report.cacheHits, privacy: .public) misses=\(report.cacheMisses, privacy: .public) \
            cacheBytes=\(report.cacheFileBytes, privacy: .public)
            """
        )

        guard let path = ProcessInfo.processInfo.environment[Self.outputKey], !path.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path))
    }

    private struct BenchmarkReport: Codable {
        let coldSeconds: Double
        let seedSeconds: Double
        let warmSeconds: Double
        let speedup: Double
        let cacheHits: Int
        let cacheMisses: Int
        let cacheFileBytes: Int64
        let totalCostUSD: Double
        let lifetimeCostUSD: Double
    }
}
