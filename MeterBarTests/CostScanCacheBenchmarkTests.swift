import Darwin
import Foundation
import os
import XCTest
@testable import MeterBar

/// Opt-in wall-clock benchmark for the incremental scan cache.
///
/// Reads the machine's **real** `~/.claude*` and `~/.codex` corpora, so it is
/// gated the same way `APIIntegrationTests` is: skipped unless explicitly asked
/// for. A developer box holds gigabytes of archived transcripts and CI holds
/// none, so the numbers are meaningless anywhere but the machine that produced
/// them, and the runtime (hours, cold) has no business in the default suite.
///
/// Enable with:
/// ```
/// METERBAR_SCAN_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
///     --filter CostScanCacheBenchmarkTests
/// ```
///
/// Release matters: a debug build spends its time in retain/release and bounds
/// checks rather than in the parse this is trying to characterise, and it is not
/// what ships.
///
/// Set `METERBAR_SCAN_BENCHMARK_OUTPUT=/path/to/result.json` to also write the
/// measurements to disk; each test writes a `-<label>.json` sibling of that path
/// and rewrites it **after every pass**, so a run that is interrupted still
/// leaves the passes it finished behind. Otherwise the numbers go to the unified
/// log only, since the repo forbids `print`.
///
/// The two tests below are deliberately split, because timing and equality want
/// opposite corpora:
///
/// - **Equality** needs a corpus that cannot move. A cold pass over this machine
///   takes hours, and anything the developer does meanwhile — including running
///   this very benchmark from an agent session that writes its own transcript —
///   appends to the live corpus. Cold and warm would then legitimately disagree,
///   and the disagreement would say nothing about the cache.
/// - **Timing** needs the real corpus, at its real size, through the real entry
///   point, or the headline number is a lab result.
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

    /// Cold versus warm over a **frozen** copy of the real Codex rollouts, where
    /// "identical to the cent" is a claim that can actually be made.
    ///
    /// `~/.codex/sessions` is cloned into a scratch `CODEX_HOME` first. The clone
    /// is an APFS `clonefile`, so it is effectively instant and costs no disk —
    /// but the point is not speed, it is that the bytes under the scanner stop
    /// changing for the duration of the run.
    ///
    /// Codex, and not Claude, because Codex is the half that can be redirected:
    /// `CodexHomeDirectory` honours `CODEX_HOME`, whereas `ClaudeCostScanner`
    /// always adds roots derived from `ServiceSupport.realHomeDirectory()`, which
    /// reads `getpwuid` precisely so a sandboxed build cannot be fooled by `HOME`.
    /// The Claude digest is covered exhaustively by `CostScanCacheTests` instead,
    /// on fixtures that hold still by construction.
    ///
    /// `sessions` alone, not the whole Codex home: `archived_sessions` is another
    /// ~8 GB and would put the cold pass back into the hours. `sessions` is a
    /// complete scanner root of real, unmodified rollouts, which is what makes
    /// this worth running at all over the synthetic fixtures.
    func testWarmSummaryMatchesColdSummaryOnAFrozenCorpus() throws {
        let liveSessions = URL(fileURLWithPath: CodexHomeDirectory.path(), isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: liveSessions.path),
            "No Codex rollouts at \(liveSessions.path) to freeze."
        )

        let frozenHome = tempDirectory.appendingPathComponent("frozen-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: frozenHome, withIntermediateDirectories: true)
        try Self.freeze(liveSessions, into: frozenHome.appendingPathComponent("sessions", isDirectory: true))

        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", frozenHome.path, 1)
        defer {
            if let previousHome {
                setenv("CODEX_HOME", previousHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }
        // No `logs_2.sqlite` is cloned, so the SQLite path stays out of this. It
        // is uncached by design, and including it would measure the same rows
        // twice rather than the cache.

        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        var report = BenchmarkReport()
        report.rolloutFiles = Self.jsonlCount(under: frozenHome)

        let cold = Self.measure { Self.makeSummary(codexOnly: true, cacheURL: nil) }
        report.cold = cold.pass
        try Self.publish(report, label: "frozen")

        let seeded = Self.measure { Self.makeSummary(codexOnly: true, cacheURL: cacheURL) }
        report.seed = seeded.pass
        report.cacheFileBytes = Self.fileSize(at: cacheURL)
        let counts = Self.entryCounts(at: cacheURL)
        report.cachedClaudeEntries = counts.claude
        report.cachedCodexEntries = counts.codex
        try Self.publish(report, label: "frozen")

        let warm = Self.measure { Self.makeSummary(codexOnly: true, cacheURL: cacheURL) }
        report.warm = warm.pass
        report.speedup = warm.pass.seconds > 0 ? cold.pass.seconds / warm.pass.seconds : 0
        report.totalCostUSD = cold.value.totalCostUSD
        report.lifetimeCostUSD = cold.value.lifetime?.totalCostUSD ?? 0
        try Self.publish(report, label: "frozen")

        // The whole point of the exercise: faster, and identical to the cent.
        Self.assertSameSummary(cold.value, warm.value)
        XCTAssertLessThan(
            warm.pass.seconds,
            cold.pass.seconds,
            "a warm scan that is not faster is a cache doing nothing"
        )
    }

    /// Wall-clock over the true corpus — every Claude root and the whole Codex
    /// home — through the production entry point the refresh loop calls.
    ///
    /// Timing only. The live corpus grows while this runs, so cold and warm read
    /// genuinely different bytes and comparing their totals would be measuring
    /// the developer's own activity. Equality is asserted on the frozen corpus
    /// above, and on fixtures in `CostScanCacheTests`.
    func testWarmScanOverTheLiveCorpusIsFaster() throws {
        let cacheURL = tempDirectory.appendingPathComponent(CostScanCacheStore.cacheFileName)
        var report = BenchmarkReport()

        let cold = Self.measure { Self.makeSummary(codexOnly: false, cacheURL: nil) }
        report.cold = cold.pass
        try Self.publish(report, label: "live")

        try XCTSkipUnless(
            cold.pass.seconds > 0.05,
            "Cold scan took \(cold.pass.seconds)s; this corpus is too small to benchmark reliably."
        )

        // Not compared against: this is the run that pays for the cache the warm
        // run reads. Recorded because "what does the first cached scan cost" is
        // a question anyone reading these numbers will ask.
        let seeded = Self.measure { Self.makeSummary(codexOnly: false, cacheURL: cacheURL) }
        report.seed = seeded.pass
        report.cacheFileBytes = Self.fileSize(at: cacheURL)
        let counts = Self.entryCounts(at: cacheURL)
        report.cachedClaudeEntries = counts.claude
        report.cachedCodexEntries = counts.codex
        try Self.publish(report, label: "live")

        let warm = Self.measure { Self.makeSummary(codexOnly: false, cacheURL: cacheURL) }
        report.warm = warm.pass
        report.speedup = warm.pass.seconds > 0 ? cold.pass.seconds / warm.pass.seconds : 0
        report.totalCostUSD = warm.value.totalCostUSD
        report.lifetimeCostUSD = warm.value.lifetime?.totalCostUSD ?? 0
        try Self.publish(report, label: "live")

        XCTAssertLessThan(
            warm.pass.seconds,
            cold.pass.seconds,
            "a warm scan that is not faster is a cache doing nothing"
        )
    }

    // MARK: - Helpers

    /// Copy-on-write clone of a whole directory tree, falling back to a real copy
    /// when the destination is not on the same APFS volume.
    private static func freeze(_ source: URL, into destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func makeSummary(codexOnly: Bool, cacheURL: URL?) -> CostSummary {
        CostSummaryBuilder.makeSummary(
            days: 30,
            includeClaudeCode: !codexOnly,
            includeCodexCli: true,
            claudeAccounts: codexOnly ? [] : [ClaudeCodeAccount.defaultAccount],
            scanCacheURL: cacheURL
        )
    }

    private static func measure<Value>(_ body: () -> Value) -> (value: Value, pass: PassMeasurement) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = body()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let memory = Self.memoryFootprint()
        return (
            value,
            PassMeasurement(
                seconds: Double(elapsed) / 1_000_000_000,
                residentBytes: memory.resident,
                peakResidentBytes: memory.peak
            )
        )
    }

    /// Resident size now, and the high-water mark since the process started.
    ///
    /// The peak is monotonic across passes by construction, so it answers "did
    /// this process ever balloon" rather than "did *this* pass balloon" — which
    /// is the question worth asking of a menu bar app that scans in the
    /// background.
    private static func memoryFootprint() -> (resident: UInt64, peak: UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, info.resident_size_max)
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func jsonlCount(under root: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        return walker.reduce(into: 0) { total, entry in
            if let url = entry as? URL, url.pathExtension == "jsonl" { total += 1 }
        }
    }

    /// Entry counts come from the persisted file rather than a fresh scan: an
    /// extra traversal of a ten gigabyte corpus is a lot to pay for two integers
    /// that the cache already wrote down.
    private static func entryCounts(at url: URL) -> (claude: Int, codex: Int) {
        guard let file = CostScanCacheStore.load(from: url) else { return (0, 0) }
        return (file.claude.count, file.codex.count)
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

    private static func publish(_ report: BenchmarkReport, label: String) throws {
        AppLog.cost.notice(
            """
            cost scan benchmark [\(label, privacy: .public)]: \
            cold=\(report.cold.seconds, privacy: .public)s \
            seed=\(report.seed.seconds, privacy: .public)s \
            warm=\(report.warm.seconds, privacy: .public)s \
            speedup=\(report.speedup, privacy: .public)x \
            peakRSS=\(report.warm.peakResidentBytes, privacy: .public) \
            cacheBytes=\(report.cacheFileBytes, privacy: .public)
            """
        )

        guard let path = ProcessInfo.processInfo.environment[Self.outputKey], !path.isEmpty else { return }
        let base = URL(fileURLWithPath: path)
        let labelled = base
            .deletingLastPathComponent()
            .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(label)")
            .appendingPathExtension(base.pathExtension.isEmpty ? "json" : base.pathExtension)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: labelled, options: .atomic)
    }

    private struct PassMeasurement: Codable {
        var seconds: Double = 0
        var residentBytes: UInt64 = 0
        var peakResidentBytes: UInt64 = 0
    }

    private struct BenchmarkReport: Codable {
        var cold = PassMeasurement()
        var seed = PassMeasurement()
        var warm = PassMeasurement()
        var speedup: Double = 0
        var cacheFileBytes: Int64 = 0
        var cachedClaudeEntries: Int = 0
        var cachedCodexEntries: Int = 0
        var rolloutFiles: Int = 0
        var totalCostUSD: Double = 0
        var lifetimeCostUSD: Double = 0
    }
}
