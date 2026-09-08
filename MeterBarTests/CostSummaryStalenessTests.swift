import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Issue #517: the daily-usage sparkline froze after the day's first cost
/// scan because `needsMissing*` trusted "a scan ran today" as proof the
/// cache was current. These cover the evidence-based replacement — real
/// disk evidence (or its absence) drives the gate instead of the calendar —
/// and the anti-thrash guarantee it must preserve: a genuinely quiet day
/// must not trigger a rescan on every hover.
final class CostSummaryStalenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // MARK: - needsMissingDailyUsageRefresh

    /// Mirrors the issue's repro: a scan ran earlier today before any usage
    /// existed, so today has no daily row yet. Real evidence that a
    /// transcript changed since that scan must reopen the gate.
    func testNeedsMissingDailyUsageRefreshReturnsTrueWhenATranscriptChangedAfterLastScan() {
        let summary = makeDailySummary(rowsForDaysAgo: [1], days: 2)

        XCTAssertTrue(
            summary.needsMissingDailyUsageRefresh(
                days: 2,
                lastScanDate: now,
                newTranscriptsSinceLastScan: true,
                now: now,
                calendar: calendar
            )
        )
    }

    /// No-thrash guarantee: today's row is still missing, but nothing on disk
    /// has changed since the scan, so this must not fire — a genuinely quiet
    /// day cannot rescan on every hover.
    func testNeedsMissingDailyUsageRefreshReturnsFalseWhenNothingChangedSinceLastScan() {
        let summary = makeDailySummary(rowsForDaysAgo: [1], days: 2)

        XCTAssertFalse(
            summary.needsMissingDailyUsageRefresh(
                days: 2,
                lastScanDate: now,
                newTranscriptsSinceLastScan: false,
                now: now,
                calendar: calendar
            )
        )
    }

    /// `America/Santiago` springs forward *at* local midnight on 2026-09-06,
    /// so `startOfDay(now)` on that day is 01:00, not 00:00. Computing the
    /// window's `startDate` by stepping back from that instant without
    /// re-normalizing every hop preserves 01:00 on the earlier day, so a row
    /// that really is inside the window falls outside the `>=` bound and the
    /// cache reports itself as under-covered when it is not — triggering a
    /// rescan on every appearance. The UTC-pinned fixtures above cannot
    /// exercise this — UTC never observes DST.
    func testNeedsMissingDailyUsageRefreshDoesNotMisreportCoverageAcrossTheSantiagoTransition() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago") ?? .current
        let dstNow = ISO8601DateFormatter().date(from: "2026-09-06T13:00:00Z") ?? now

        func exactDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            let date = santiago.date(from: components) ?? dstNow
            return santiago.startOfDay(for: date)
        }

        XCTAssertEqual(santiago.component(.hour, from: exactDay(2026, 9, 6)), 1)

        let rows = [
            DailyTokenUsage(
                date: exactDay(2026, 9, 6).addingTimeInterval(3600 * 2),
                provider: .claudeCode,
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                estimatedCostUSD: 0.05,
                modelBreakdowns: [],
                projectBreakdowns: [],
                sessionBreakdowns: []
            ),
            DailyTokenUsage(
                date: exactDay(2026, 9, 5).addingTimeInterval(3600 * 5),
                provider: .claudeCode,
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                estimatedCostUSD: 0.05,
                modelBreakdowns: [],
                projectBreakdowns: [],
                sessionBreakdowns: []
            ),
        ]
        let summary = makeSummary(periodDays: 2, dailyUsage: rows, hourlyUsage: nil)

        XCTAssertFalse(
            summary.needsMissingDailyUsageRefresh(
                days: 2,
                lastScanDate: nil,
                now: dstNow,
                calendar: santiago
            )
        )
    }

    // MARK: - needsMissingHourlyUsageRefresh

    func testNeedsMissingHourlyUsageRefreshReturnsTrueWhenATranscriptChangedAfterLastScan() {
        let summary = makeSummary(periodDays: 7, dailyUsage: [], hourlyUsage: nil)

        XCTAssertTrue(
            summary.needsMissingHourlyUsageRefresh(
                lastScanDate: now,
                newTranscriptsSinceLastScan: true,
                now: now,
                calendar: calendar
            )
        )
    }

    func testNeedsMissingHourlyUsageRefreshReturnsFalseWhenNothingChangedSinceLastScan() {
        let summary = makeSummary(periodDays: 7, dailyUsage: [], hourlyUsage: nil)

        XCTAssertFalse(
            summary.needsMissingHourlyUsageRefresh(
                lastScanDate: now,
                newTranscriptsSinceLastScan: false,
                now: now,
                calendar: calendar
            )
        )
    }

    // MARK: - needsMissingEnabledProviderRefresh

    func testNeedsMissingEnabledProviderRefreshReturnsTrueWhenATranscriptChangedAfterLastScan() {
        let summary = makeSummary(periodDays: 30, dailyUsage: [], hourlyUsage: nil)

        XCTAssertTrue(
            summary.needsMissingEnabledProviderRefresh(
                enabledServices: [.claudeCode, .grok],
                lastScanDate: now,
                newTranscriptsSinceLastScan: true,
                now: now,
                calendar: calendar
            )
        )
    }

    func testNeedsMissingEnabledProviderRefreshReturnsFalseWhenNothingChangedSinceLastScan() {
        let summary = makeSummary(periodDays: 30, dailyUsage: [], hourlyUsage: nil)

        XCTAssertFalse(
            summary.needsMissingEnabledProviderRefresh(
                enabledServices: [.claudeCode, .grok],
                lastScanDate: now,
                newTranscriptsSinceLastScan: false,
                now: now,
                calendar: calendar
            )
        )
    }

    // MARK: - Unknown evidence (unwalkable root) falls back to a time threshold

    func testUnknownEvidenceWithinTheFallbackWindowStaysCurrent() {
        let summary = makeDailySummary(rowsForDaysAgo: [1], days: 2)
        let lastScanDate = now.addingTimeInterval(-5 * 60)

        XCTAssertFalse(
            summary.needsMissingDailyUsageRefresh(
                days: 2,
                lastScanDate: lastScanDate,
                newTranscriptsSinceLastScan: nil,
                now: now,
                calendar: calendar
            )
        )
    }

    func testUnknownEvidenceBeyondTheFallbackWindowIsTreatedAsPossiblyStale() {
        let summary = makeDailySummary(rowsForDaysAgo: [1], days: 2)
        let lastScanDate = now.addingTimeInterval(-20 * 60)

        XCTAssertTrue(
            summary.needsMissingDailyUsageRefresh(
                days: 2,
                lastScanDate: lastScanDate,
                newTranscriptsSinceLastScan: nil,
                now: now,
                calendar: calendar
            )
        )
    }

    // MARK: - CostTracker.needsBackgroundRefresh composition

    /// Disables the hourly check (`periodDays: 1`) and matches enabled
    /// services to the providers already present in `costs` (disables the
    /// missing-provider check), so only `needsMissingDailyUsageRefresh` can
    /// flip the composed result — isolating the probe wiring end to end.
    ///
    /// `needsBackgroundRefresh` has no `calendar:` parameter of its own — it
    /// forwards to each `needsMissing*` default (`.current`), so this (like
    /// `CostScanWindowOnlyTests`) builds its fixture against `Calendar.current`
    /// and real "now" rather than the fixed UTC clock the rest of this file
    /// uses, to avoid a timezone-dependent day boundary mismatch.
    func testNeedsBackgroundRefreshComposesTheThreeChecksUsingTheInjectedProbe() {
        let now = Date()
        let summary = makeSystemCalendarDailySummary(daysAgo: [1], now: now, periodDays: 1)
        var capturedDate: Date?
        var capturedServices: Set<ServiceType>?

        let refreshesWithEvidence = CostTracker.needsBackgroundRefresh(
            summary: summary,
            lastScanDate: now,
            enabledServices: [.claudeCode],
            days: 2,
            now: now,
            newTranscriptsSinceLastScan: { date, services in
                capturedDate = date
                capturedServices = services
                return true
            }
        )
        XCTAssertTrue(refreshesWithEvidence)
        XCTAssertEqual(capturedDate, now)
        XCTAssertEqual(capturedServices, [.claudeCode])

        let refreshesWithoutEvidence = CostTracker.needsBackgroundRefresh(
            summary: summary,
            lastScanDate: now,
            enabledServices: [.claudeCode],
            days: 2,
            now: now,
            newTranscriptsSinceLastScan: { _, _ in false }
        )
        XCTAssertFalse(refreshesWithoutEvidence)
    }

    func testNeedsBackgroundRefreshDoesNotProbeDiskWithoutAPriorScan() {
        let now = Date()
        let summary = makeSystemCalendarDailySummary(daysAgo: [1], now: now)

        let result = CostTracker.needsBackgroundRefresh(
            summary: summary,
            lastScanDate: nil,
            enabledServices: [.claudeCode],
            days: 2,
            now: now,
            newTranscriptsSinceLastScan: { _, _ in
                XCTFail("the probe has nothing to compare against without a lastScanDate")
                return nil
            }
        )

        XCTAssertTrue(result, "no prior scan is itself reason enough to backfill")
    }

    // MARK: - CostScanFreshnessProbe (the root-walking half, injected roots)

    func testProbeReturnsTrueWhenARootHoldsATranscriptModifiedAfterTheDate() throws {
        let root = try makeCorpusDirectory()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "fresh.jsonl", modified: cutoff.addingTimeInterval(60))

        let evidence = CostScanFreshnessProbe.hasNewTranscripts(in: [root], since: cutoff)

        XCTAssertTrue(try XCTUnwrap(evidence))
    }

    /// Anti-thrash at the probe level: a fully walkable root with nothing
    /// newer than the cutoff must answer `false`, not `nil`.
    func testProbeReturnsFalseWhenNothingChangedSinceTheDate() throws {
        let root = try makeCorpusDirectory()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "old.jsonl", modified: cutoff.addingTimeInterval(-60))

        let evidence = CostScanFreshnessProbe.hasNewTranscripts(in: [root], since: cutoff)

        XCTAssertFalse(try XCTUnwrap(evidence))
    }

    func testProbeReturnsNilWhenARootCannotBeWalked() throws {
        let root = try makeCorpusDirectory()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try writeCorpusFile(in: locked, name: "hidden.jsonl", modified: cutoff.addingTimeInterval(60))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let evidence = CostScanFreshnessProbe.hasNewTranscripts(in: [root], since: cutoff)

        XCTAssertNil(evidence)
    }

    func testProbeOnlyCountsNamedFilesWhenFiltered() throws {
        let root = try makeCorpusDirectory()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
        try writeCorpusFile(in: root, name: "messages.jsonl", modified: cutoff.addingTimeInterval(60))

        let evidence = CostScanFreshnessProbe.hasNewTranscripts(
            in: [root],
            since: cutoff,
            fileNames: ["updates.jsonl"]
        )

        XCTAssertFalse(
            try XCTUnwrap(evidence),
            "a newer file that doesn't match the provider's own filter is not evidence"
        )
    }

    // MARK: - Fixtures

    private func makeDailySummary(rowsForDaysAgo daysAgo: [Int], days: Int, periodDays: Int? = nil) -> CostSummary {
        let today = calendar.startOfDay(for: now)
        let rows = daysAgo.map { offset -> DailyTokenUsage in
            DailyTokenUsage(
                date: calendar.date(byAdding: .day, value: -offset, to: today) ?? today,
                provider: .claudeCode,
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                estimatedCostUSD: 0.05,
                modelBreakdowns: [],
                projectBreakdowns: [],
                sessionBreakdowns: []
            )
        }
        return makeSummary(periodDays: periodDays ?? days, dailyUsage: rows, hourlyUsage: nil)
    }

    /// Same shape as `makeDailySummary`, but dated against `Calendar.current`
    /// for callers (`CostTracker.needsBackgroundRefresh`) that always resolve
    /// the day boundary with the system calendar.
    private func makeSystemCalendarDailySummary(daysAgo: [Int], now: Date, periodDays: Int = 2) -> CostSummary {
        let systemCalendar = Calendar.current
        let today = systemCalendar.startOfDay(for: now)
        let rows = daysAgo.map { offset -> DailyTokenUsage in
            DailyTokenUsage(
                date: systemCalendar.date(byAdding: .day, value: -offset, to: today) ?? today,
                provider: .claudeCode,
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                estimatedCostUSD: 0.05,
                modelBreakdowns: [],
                projectBreakdowns: [],
                sessionBreakdowns: []
            )
        }
        return makeSummary(periodDays: periodDays, dailyUsage: rows, hourlyUsage: nil)
    }

    private func makeSummary(
        periodDays: Int,
        dailyUsage: [DailyTokenUsage],
        hourlyUsage: [HourlyTokenUsage]?
    ) -> CostSummary {
        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: 100,
            outputTokens: 20,
            cacheCreationTokens: 0,
            cacheReadTokens: 5,
            estimatedCostUSD: 1.25,
            sessionCount: 1,
            periodStart: now,
            periodEnd: now
        )
        return CostSummary(
            costs: [cost],
            totalCostUSD: cost.estimatedCostUSD,
            totalTokens: cost.totalTokens,
            periodDays: periodDays,
            dailyUsage: dailyUsage,
            hourlyUsage: hourlyUsage
        )
    }

    private func makeCorpusDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostSummaryStaleness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeCorpusFile(in root: URL, name: String, modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
