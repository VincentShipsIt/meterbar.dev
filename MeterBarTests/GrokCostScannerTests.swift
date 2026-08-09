import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Unit tests for `GrokCostScanner` — the third cost corpus (issue: Grok is
/// quota-tracked but contributed no `costs[]`/`dailyUsage[]` rows, so it was
/// structurally absent from the spend chart and the share card).
///
/// Grok reports spend itself, so the load-bearing facts here are not a pricing
/// table but the *shape* of what it reports: the tick scale, that cached reads
/// sit inside `inputTokens`, that reasoning sits inside `outputTokens`, and that
/// records are per-turn increments rather than running totals. Each has its own
/// test because getting any one wrong produces a plausible-looking number.
final class GrokCostScannerTests: XCTestCase {
    // MARK: - Tick scale

    /// The reconciliation that pinned `usdPerCostTick`, asserted on a fixed
    /// record so a future edit to the constant fails here rather than silently
    /// restating every Grok total by a factor of ten.
    ///
    /// Token counts and `costUsdTicks` below are observed values from a real
    /// `updates.jsonl` turn with `modelCalls == 1` — a single call, so no
    /// >200k-context surcharge can be hiding in the total. Holding xAI's
    /// published grok-4.5 rates fixed ($2.00/M fresh input, $6.00/M output) and
    /// solving for the cached-input rate yields exactly $0.300/M at this scale.
    /// At 1e-9 the same row implies $3.00/M cached input — 1.5x the *fresh*
    /// input rate, which no cache discount can be.
    func testCostTickScaleReproducesTheVerifiedDollarAmountForAKnownRecord() {
        let ticks = 532_640_000

        let usd = Double(ticks) * GrokCostScanner.usdPerCostTick

        XCTAssertEqual(usd, 0.053264, accuracy: 1e-9)
    }

    /// The same record, end to end: what the scanner publishes has to equal the
    /// figure the constant reconciles to, not merely be derived from it.
    func testScannedRecordPublishesTheCostGrokReportedRatherThanARecomputedOne() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "019fafec-972e-7413-8cbd-01647988c8f9",
            lines: [turnCompleted(at: now, input: 173_272, cachedRead: 172_800, output: 80, reasoning: 40, ticks: 532_640_000)]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.estimatedCostUSD, 0.053264, accuracy: 1e-9)
    }

    // MARK: - Token semantics

    /// `cachedReadTokens` is a *subset* of `inputTokens` — every observed record
    /// satisfies `totalTokens == inputTokens + outputTokens` with
    /// `cachedReadTokens <= inputTokens`. Reporting the raw `inputTokens`
    /// alongside `cacheReadTokens` would bill the cached prefix twice and inflate
    /// `totalTokens` past what Grok itself reported for the turn.
    func testCachedReadTokensAreSubtractedFromInputRatherThanCountedTwice() throws {
        let root = try makeSessionsRoot()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 60_800, cachedRead: 60_547, output: 503, reasoning: 120, ticks: 217_640_000)]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 253, "fresh input only")
        XCTAssertEqual(cost.cacheReadTokens, 60_547)
        XCTAssertEqual(cost.totalTokens, 60_800 + 503, "must match Grok's own totalTokens")
    }

    /// Codex reports reasoning tokens *outside* `output_tokens`, so its scanner
    /// adds them on. Grok reports them inside `outputTokens`
    /// (`reasoningTokens < outputTokens` in every observed record), so adding
    /// them again would double-count the most expensive tokens on the bill.
    func testReasoningTokensAreNotAddedOnTopOfOutputTokens() throws {
        let root = try makeSessionsRoot()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 1_000, cachedRead: 0, output: 500, reasoning: 400, ticks: 5_000_000)]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.outputTokens, 500)
    }

    /// Records are per-turn increments, not running totals — verified
    /// non-monotonic within a single session on disk. Summing is therefore
    /// correct; taking the last record would drop everything before it.
    func testPerTurnRecordsAreSummedBecauseTheyAreIncrementalNotCumulative() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                turnCompleted(at: now.addingTimeInterval(-300), input: 276_435, cachedRead: 0, output: 100, reasoning: 0, ticks: 10_000_000),
                turnCompleted(at: now.addingTimeInterval(-200), input: 121_551, cachedRead: 0, output: 200, reasoning: 0, ticks: 20_000_000),
                turnCompleted(at: now.addingTimeInterval(-100), input: 61_053, cachedRead: 0, output: 300, reasoning: 0, ticks: 30_000_000)
            ]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 276_435 + 121_551 + 61_053)
        XCTAssertEqual(cost.outputTokens, 600)
        XCTAssertEqual(cost.estimatedCostUSD, 0.006, accuracy: 1e-9)
    }

    // MARK: - Envelope tolerance

    /// Grok writes the same `session/update` envelope under a vendor-prefixed
    /// method name as well. Both carry real spend; matching only the bare name
    /// silently dropped every record written under the prefixed one.
    func testVendorPrefixedSessionUpdateMethodIsCountedTheSameAsThePlainOne() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                turnCompleted(at: now.addingTimeInterval(-60), input: 10, cachedRead: 0, output: 5, reasoning: 0, ticks: 1_000_000),
                turnCompleted(
                    at: now,
                    input: 20,
                    cachedRead: 0,
                    output: 7,
                    reasoning: 0,
                    ticks: 2_000_000,
                    method: "_x.ai/session/update"
                )
            ]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 30)
        XCTAssertEqual(cost.outputTokens, 12)
    }

    /// `updates.jsonl` is a full transport log: tool calls, agent messages, and
    /// permission prompts share the file with the handful of `turn_completed`
    /// lines that carry usage. Only the latter may be tallied.
    func testUpdatesWithoutATurnCompletedUsageBlobContributeNothing() throws {
        let root = try makeSessionsRoot()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                #"{"timestamp":1785363000,"method":"session/update","params":{"sessionId":"session-a","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}"#,
                #"{"timestamp":1785363001,"method":"session/request_permission","params":{"sessionId":"session-a"}}"#
            ]
        )

        XCTAssertNil(scanCost(roots: [root], days: 30))
    }

    /// A partially-flushed final line is the normal state of a session that is
    /// still running. It must cost the scan that one record, never the file.
    func testMalformedLinesAreSkippedWithoutAbortingTheRestOfTheFile() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                turnCompleted(at: now.addingTimeInterval(-120), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000),
                "{not json at all",
                #"{"timestamp":"not-a-number","method":"session/update"}"#,
                turnCompleted(at: now, input: 200, cachedRead: 0, output: 20, reasoning: 0, ticks: 2_000_000)
            ]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 300)
        XCTAssertEqual(cost.outputTokens, 30)
    }

    /// `isFinite` is not the same test as "fits in `Int`": `1e300` is finite and
    /// its millisecond value is ~1e303, which trapped the whole scan when the
    /// dedup key converted it. A corrupt timestamp may only cost its own record.
    func testTimestampsTooLargeForWholeMillisecondsDropOnlyTheirOwnRecord() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                turnCompleted(at: now.addingTimeInterval(-120), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000),
                turnCompleted(rawTimestamp: "1e300", input: 999, output: 999, ticks: 9_000_000),
                turnCompleted(rawTimestamp: "-1e300", input: 999, output: 999, ticks: 9_000_000),
                turnCompleted(at: now, input: 200, cachedRead: 0, output: 20, reasoning: 0, ticks: 2_000_000)
            ]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 300)
        XCTAssertEqual(cost.outputTokens, 30)
    }

    /// Overriding `GROK_HOME` has to hand back exactly what the process started
    /// with. Unsetting it unconditionally repoints the session root for every
    /// later test in the same process whenever the developer's shell exports one.
    func testOverridingGrokHomeRestoresThePreexistingValue() {
        setenv("GROK_HOME", "/tmp/meterbar-preexisting-grok", 1)
        defer { unsetenv("GROK_HOME") }

        let restore = Self.overrideGrokHome("/tmp/meterbar-fixture-grok")
        XCTAssertEqual(ProcessInfo.processInfo.environment["GROK_HOME"], "/tmp/meterbar-fixture-grok")

        restore()

        XCTAssertEqual(ProcessInfo.processInfo.environment["GROK_HOME"], "/tmp/meterbar-preexisting-grok")
    }

    /// The other half of the contract: with nothing set going in, the override
    /// has to leave nothing set going out.
    func testOverridingGrokHomeClearsItWhenNothingWasSet() {
        unsetenv("GROK_HOME")

        let restore = Self.overrideGrokHome("/tmp/meterbar-fixture-grok")
        restore()

        XCTAssertNil(ProcessInfo.processInfo.environment["GROK_HOME"])
    }

    /// One turn re-logged verbatim (a retried write) must not be billed twice.
    func testIdenticalRecordsInOneFileAreCountedOnce() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        let line = turnCompleted(at: now, input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)
        try writeUpdates(in: root, project: "www/meterbar", session: "session-a", lines: [line, line])

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.inputTokens, 100)
    }

    // MARK: - Windowing

    /// The period window is the visible 30-day chart; the lifetime window is the
    /// share card's all-time figure. One traversal has to fill both correctly.
    func testRecordsOlderThanTheCutoffCountTowardLifetimeButNotThePeriod() throws {
        let root = try makeSessionsRoot()
        let now = Date()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [
                turnCompleted(at: now.addingTimeInterval(-60 * 60 * 24 * 90), input: 900, cachedRead: 0, output: 90, reasoning: 0, ticks: 9_000_000),
                turnCompleted(at: now, input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)
            ]
        )
        let session = CostScanSession(cutoff: CostWindow.start(days: 30), options: .unlimited)

        let windows = GrokCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(try XCTUnwrap(GrokCostScanner.makeCost(from: windows.period)).0.inputTokens, 100)
        XCTAssertEqual(try XCTUnwrap(GrokCostScanner.makeCost(from: windows.lifetime)).0.inputTokens, 1_000)
    }

    /// The daily rows are what the spend chart plots. Their totals have to
    /// reconcile with Grok's own `totalTokens` for the same turns.
    func testDailyUsageRowsCarryTheGrokProviderAndReconcileWithItsReportedTotal() throws {
        let root = try makeSessionsRoot()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 5_000, cachedRead: 4_000, output: 250, reasoning: 100, ticks: 3_000_000)]
        )

        let daily = try XCTUnwrap(scanDaily(roots: [root], days: 30)).first

        let row = try XCTUnwrap(daily)
        XCTAssertEqual(row.provider, .grok)
        XCTAssertEqual(row.inputTokens, 1_000)
        XCTAssertEqual(row.outputTokens, 250)
        XCTAssertEqual(row.cacheReadTokens, 4_000)
        XCTAssertEqual(row.totalTokens, 5_250)
        XCTAssertEqual(row.estimatedCostUSD, 0.0003, accuracy: 1e-9)
    }

    func testScanAccumulatesOnlyTrailingSevenDaysIntoHourlyBuckets() throws {
        let root = try makeSessionsRoot()
        let periodCutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let currentHour = try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: Date())?.start)
        let hourlyCutoff = currentHour.addingTimeInterval(-7 * 24 * 60 * 60)
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-hourly",
            lines: [
                turnCompleted(
                    at: hourlyCutoff.addingTimeInterval(-60),
                    input: 90,
                    cachedRead: 0,
                    output: 9,
                    reasoning: 0,
                    ticks: 900_000
                ),
                turnCompleted(
                    at: hourlyCutoff,
                    input: 50,
                    cachedRead: 0,
                    output: 5,
                    reasoning: 0,
                    ticks: 500_000
                ),
                turnCompleted(
                    at: hourlyCutoff.addingTimeInterval(3_599),
                    input: 100,
                    cachedRead: 10,
                    output: 10,
                    reasoning: 0,
                    ticks: 1_000_000
                ),
                turnCompleted(
                    at: hourlyCutoff.addingTimeInterval(3_600),
                    input: 200,
                    cachedRead: 20,
                    output: 20,
                    reasoning: 0,
                    ticks: 2_000_000
                ),
            ]
        )
        let session = CostScanSession(
            cutoff: periodCutoff,
            hourlyCutoff: hourlyCutoff,
            options: .unlimited
        )

        let rows = try XCTUnwrap(GrokCostScanner.makeCost(
            from: GrokCostScanner.scanRoots([root], session: session).period
        )?.2)

        XCTAssertEqual(rows.count, 2, "the cutoff event shares an hour bucket with the next event")
        XCTAssertEqual(rows.map(\.provider), [.grok, .grok])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, 385)
    }

    // MARK: - Attribution

    /// Grok names each session directory after the URL-encoded absolute project
    /// path. Decoding it is the only way the per-project rollup can name a
    /// worktree; the home prefix is stripped for the same privacy reason Claude
    /// and Codex strip theirs.
    func testProjectAttributionPercentDecodesTheSessionDirectoryName() {
        let home = ServiceSupport.realHomeDirectory()
        let encoded = "\(home)/www/genfeedai/genfeed.ai"
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? ""

        let projectID = CostProjectAttribution.grokProjectID(encodedDirectoryName: encoded)

        XCTAssertEqual(projectID, "www/genfeedai/genfeed.ai")
    }

    func testProjectAttributionFallsBackToUnknownForADirectoryOutsideHome() {
        let encoded = "%2Fvar%2Ftmp%2Fsomewhere"

        XCTAssertEqual(
            CostProjectAttribution.grokProjectID(encodedDirectoryName: encoded),
            CostProjectAttribution.unknownProjectID
        )
    }

    func testProjectAndModelBreakdownsAreEmittedForTheScannedCorpus() throws {
        let root = try makeSessionsRoot()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)]
        )

        let cost = try XCTUnwrap(scanCost(roots: [root], days: 30))

        XCTAssertEqual(cost.modelBreakdowns.map(\.name), ["grok-4.5-build"])
        XCTAssertEqual(cost.projectBreakdowns.map(\.name), ["www/meterbar"])
    }

    // MARK: - Roots and resumption

    /// `GROK_HOME` and per-account home directories are the supported ways to
    /// point Grok somewhere other than `~/.grok`. A hardcoded path would scan
    /// the wrong corpus for every user who moved it.
    func testSessionRootsFollowTheAccountHomeDirectoryRatherThanAHardcodedPath() throws {
        let home = try makeTemporaryDirectory(prefix: "GrokHome")
        let account = GrokAccount(id: UUID(), name: "Work", homeDirectory: home.path)

        let roots = GrokCostScanner.sessionRoots(accounts: [account])

        XCTAssertTrue(
            roots.contains { $0.standardizedFileURL.path == home.appendingPathComponent("sessions").standardizedFileURL.path },
            "expected the account's own sessions directory, got \(roots.map(\.path))"
        )
    }

    /// The scan is budgeted and resumable: a slice commits a byte offset on a
    /// line boundary, and the next slice reads only what was appended after it.
    /// Re-reading from zero would double-count; skipping past would lose spend.
    func testAppendedRecordsAreFoldedInWithoutRecountingTheAlreadyScannedPrefix() throws {
        let root = try makeSessionsRoot()
        let store = try makeScanCacheStore()
        let now = Date()
        let url = try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: now.addingTimeInterval(-120), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)]
        )
        let cutoff = CostWindow.start(days: 30)
        let first = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        _ = GrokCostScanner.scanRoots([root], session: first)
        XCTAssertEqual(first.persist().outcome(for: .grok), .persisted)

        try append(
            turnCompleted(at: now, input: 200, cachedRead: 0, output: 20, reasoning: 0, ticks: 2_000_000) + "\n",
            to: url
        )
        let second = CostScanSession(cutoff: cutoff, options: .unlimited, store: store)
        let windows = GrokCostScanner.scanRoots([root], session: second)

        let cost = try XCTUnwrap(GrokCostScanner.makeCost(from: windows.period)).0
        XCTAssertEqual(cost.inputTokens, 300)
        XCTAssertEqual(cost.outputTokens, 30)
    }

    /// The Grok cache gets its own versioned artifact. Sharing a file with
    /// Claude or Codex would mean one provider's schema bump silently discarding
    /// another's committed offsets.
    func testGrokProgressPersistsToItsOwnVersionedArtifact() throws {
        let root = try makeSessionsRoot()
        let store = try makeScanCacheStore()
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)]
        )
        let session = CostScanSession(cutoff: CostWindow.start(days: 30), options: .unlimited, store: store)
        _ = GrokCostScanner.scanRoots([root], session: session)

        XCTAssertEqual(session.persist().outcome(for: .grok), .persisted)
        XCTAssertNotEqual(CostScanCacheStore.grokFileName, CostScanCacheStore.codexFileName)
        XCTAssertNotEqual(CostScanCacheStore.grokFileName, CostScanCacheStore.claudeFileName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.directory.appendingPathComponent(CostScanCacheStore.grokFileName).path
            )
        )
    }

    // MARK: - Summary wiring

    /// The whole point of the change: `.grok` has to reach `costs[]` and
    /// `dailyUsage[]`, and only when the provider toggle says so.
    func testSummaryIncludesGrokRowsOnlyWhenTheProviderIsEnabled() throws {
        let home = try makeTemporaryDirectory(prefix: "GrokHome")
        // `sessionRoots` always includes the default home as well as each
        // account's, because most users enable Grok without ever adding an
        // account entry. Point the default at the fixture too, or this asserts
        // against whatever the developer's own `~/.grok` happens to hold.
        addTeardownBlock(Self.overrideGrokHome(home.path))
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeUpdates(
            in: root,
            project: "www/meterbar",
            session: "session-a",
            lines: [turnCompleted(at: Date(), input: 100, cachedRead: 0, output: 10, reasoning: 0, ticks: 1_000_000)]
        )
        let accounts = [GrokAccount(id: UUID(), name: "Work", homeDirectory: home.path)]
        let cutoff = CostWindow.start(days: 30)

        let enabled = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [.grok],
            claudeAccounts: [],
            grokAccounts: accounts,
            session: CostScanSession(cutoff: cutoff, options: .unlimited)
        )
        let disabled = CostSummaryBuilder.makeScan(
            days: 30,
            enabledProviders: [],
            claudeAccounts: [],
            grokAccounts: accounts,
            session: CostScanSession(cutoff: cutoff, options: .unlimited)
        )

        XCTAssertEqual(enabled.summary.costs.map(\.provider), [.grok])
        XCTAssertEqual(enabled.summary.dailyUsage.map(\.provider), [.grok])
        XCTAssertEqual(enabled.summary.lifetime?.providers.map(\.provider), [.grok])
        XCTAssertTrue(disabled.summary.costs.isEmpty)
    }

    // MARK: - Fixtures

    /// Points `GROK_HOME` at a fixture and hands back the undo, so the caller
    /// can pass it straight to `addTeardownBlock`. Restoring the previous value
    /// rather than unsetting matters because the scanner falls back to the
    /// default home: a leaked unset would silently repoint later tests at the
    /// developer's real `~/.grok`.
    private static func overrideGrokHome(_ path: String) -> () -> Void {
        let previous = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", path, 1)
        return {
            if let previous {
                setenv("GROK_HOME", previous, 1)
            } else {
                unsetenv("GROK_HOME")
            }
        }
    }

    /// One `turn_completed` envelope, shaped exactly like the ones on disk:
    /// usage nested at `params.update.usage`, per-model copies under
    /// `modelUsage`, and a whole-second `timestamp`.
    private func turnCompleted(
        at date: Date,
        input: Int,
        cachedRead: Int,
        output: Int,
        reasoning: Int,
        ticks: Int,
        method: String = "session/update"
    ) -> String {
        let usage = """
            {"inputTokens":\(input),"outputTokens":\(output),"totalTokens":\(input + output),\
            "cachedReadTokens":\(cachedRead),"reasoningTokens":\(reasoning),"modelCalls":1,\
            "apiDurationMs":1234,"costUsdTicks":\(ticks),\
            "modelUsage":{"grok-4.5-build":{"inputTokens":\(input),"outputTokens":\(output),\
            "cachedReadTokens":\(cachedRead),"reasoningTokens":\(reasoning),"costUsdTicks":\(ticks)}},\
            "numTurns":1}
            """
        return """
            {"timestamp":\(Int(date.timeIntervalSince1970)),"method":"\(method)",\
            "params":{"sessionId":"019fafec-972e-7413-8cbd-01647988c8f9",\
            "update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn","usage":\(usage)}}}
            """
    }

    /// The same envelope with the `timestamp` written verbatim, so a test can
    /// feed a value that is valid JSON and a finite `Double` yet has no whole
    /// millisecond representation — `1e300`. Interpolating it as text is the
    /// only way to express that: `Date` cannot carry it.
    private func turnCompleted(rawTimestamp: String, input: Int, output: Int, ticks: Int) -> String {
        let usage = """
            {"inputTokens":\(input),"outputTokens":\(output),"totalTokens":\(input + output),\
            "cachedReadTokens":0,"reasoningTokens":0,"modelCalls":1,\
            "apiDurationMs":1234,"costUsdTicks":\(ticks),"numTurns":1}
            """
        return """
            {"timestamp":\(rawTimestamp),"method":"session/update",\
            "params":{"sessionId":"019fafec-972e-7413-8cbd-01647988c8f9",\
            "update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn","usage":\(usage)}}}
            """
    }

    @discardableResult
    private func writeUpdates(
        in root: URL,
        project: String,
        session: String,
        lines: [String]
    ) throws -> URL {
        let home = ServiceSupport.realHomeDirectory()
        let encoded = "\(home)/\(project)"
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? project
        let directory = root
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("updates.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func scanCost(roots: [URL], days: Int) -> TokenCost? {
        let session = CostScanSession(cutoff: CostWindow.start(days: days), options: .unlimited)
        return GrokCostScanner.makeCost(from: GrokCostScanner.scanRoots(roots, session: session).period)?.0
    }

    private func scanDaily(roots: [URL], days: Int) -> [DailyTokenUsage]? {
        let session = CostScanSession(cutoff: CostWindow.start(days: days), options: .unlimited)
        return GrokCostScanner.makeCost(from: GrokCostScanner.scanRoots(roots, session: session).period)?.1
    }

    private func makeSessionsRoot() throws -> URL {
        try makeTemporaryDirectory(prefix: "GrokSessions")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeScanCacheStore() throws -> CostScanCacheStore {
        CostScanCacheStore(directory: try makeTemporaryDirectory(prefix: "GrokScanCache"))
    }
}
