import Foundation
import MeterBarShared

/// Reads Grok CLI session logs and turns them into cost totals — the third
/// corpus alongside `ClaudeCostScanner` and `CodexCostScanner`.
///
/// Grok was already quota-tracked but contributed no `costs[]`/`dailyUsage[]`
/// rows, so its spend was structurally absent from the chart and the share card
/// rather than merely hidden by a toggle.
///
/// The shape mirrors the Codex scanner — same `ScanWindows`, same per-file
/// resumable cache, same budgeted line reader — minus three things Grok does
/// not need:
///
/// * **No pricing table.** Grok reports what it charged, per turn, in
///   `costUsdTicks`. A local rate card would be a second source of truth that
///   could only ever disagree with the bill.
/// * **No deferred-model queue.** A Codex `token_count` event names no model, so
///   that scanner parks events until a later line declares one. A Grok
///   `turn_completed` names its own model inside `modelUsage`, so every record
///   is attributable the moment it is read.
///
/// It does keep Codex's overlap fallback. Grok writes each session exactly
/// once, but nothing keeps a *copy* of `updates.jsonl` off disk: sync clients
/// leave conflict copies and backups get restored into the tree. The listing
/// only opens `updates.jsonl` (the rest of the session log has no usage).
/// Because the dedup key carries the session ID from the payload rather than
/// from the path, a copy produces identical keys — so a blind `merge` would
/// bill it twice.
enum GrokCostScanner {
    /// USD per unit of `costUsdTicks`.
    ///
    /// **Pinned empirically, not assumed.** Grok reports cost as an integer tick
    /// count with no documented scale, and the two candidate scales differ by
    /// 10x — enough to make every Grok figure on the chart wrong while still
    /// looking plausible.
    ///
    /// Method: take the observed records with `modelCalls == 1` (a single API
    /// call, so no >200k-context surcharge can hide inside the total), hold
    /// xAI's published grok-4.5 rates fixed ($2.00/M fresh input, $6.00/M
    /// output), and solve each record for the implied cached-input rate:
    ///
    /// ```
    /// cached   fresh  output   reported USD    implied cached rate
    ///  60,800    253     503      0.021764           $0.300/M
    ///  84,480    275     516      0.028990           $0.300/M
    /// 171,904    951     260      0.055033           $0.300/M
    /// 172,800    472      80      0.053264           $0.300/M
    /// 173,184    693      64      0.053725           $0.300/M
    /// ```
    ///
    /// Five independent records agreeing to three decimals is an exact solve,
    /// not a curve fit. At 1e-9 the same rows imply $3.00/M for *cached* input —
    /// 1.5x the fresh-input rate, which no cache discount can be. A whole-corpus
    /// cross-check agrees: against a published-rate baseline, 1e-10 puts every
    /// record between 0.61x and 1.74x (median 0.78x, the spread the 2x
    /// long-context surcharge predicts), while 1e-9 puts the median at 7.8x.
    ///
    /// Asserted on a fixed record in `GrokCostScannerTests` so editing this
    /// constant fails a test rather than silently restating every Grok total.
    nonisolated static let usdPerCostTick = 1e-10

    /// The front end this corpus is written by. Grok records carry no
    /// originator field of their own, so every event shares one origin rather
    /// than landing in "Unknown origin".
    nonisolated static let originName = "Grok CLI"

    /// Byte-level prefilter, matching the Codex scanner's `token_count` one.
    /// `updates.jsonl` is a full transport log — tool calls, message chunks,
    /// permission prompts — and only a handful of its lines carry usage, so
    /// skipping `JSONSerialization` on the rest is what keeps the scan cheap.
    nonisolated private static let turnCompletedMarker = Data("\"turn_completed\"".utf8)

    /// Seeds both windows: `earliestDate` starts at now and only decreases,
    /// `latestDate` starts at the window floor and only increases.
    nonisolated static func scanWindows(
        cutoff: Date,
        hourlyCutoff: Date = .distantPast
    ) -> ScanWindows<CostScanWindowContext> {
        ScanWindows(
            period: CostScanWindowContext(earliestDate: Date(), latestDate: cutoff),
            lifetime: CostScanWindowContext(earliestDate: Date(), latestDate: .distantPast),
            cutoff: cutoff,
            hourlyCutoff: hourlyCutoff
        )
    }

    /// The `sessions` directories to scan, one per Grok home.
    ///
    /// Resolution goes through `GrokHomeDirectory` rather than a literal
    /// `~/.grok` so `GROK_HOME` and per-account homes keep working; a hardcoded
    /// path would scan the wrong corpus — or none — for anyone who moved it.
    ///
    /// The local-volume guard is applied to the *home* directory rather than to
    /// `sessions` itself: a freshly configured account has a home but has not
    /// yet written a session, and rejecting it there would make the account
    /// invisible until its first turn. `sessions` is a child of the directory
    /// just cleared, so the network-volume protection is unchanged.
    nonisolated static func sessionRoots(accounts: [GrokAccount]) -> [URL] {
        var homes = [GrokHomeDirectory.path()]
        homes.append(contentsOf: accounts.map(GrokHomeDirectory.path(for:)))

        var roots: [URL] = []
        var seen: Set<String> = []
        for home in homes {
            let directory = URL(fileURLWithPath: home, isDirectory: true)
            guard CostScanFileSystem.isLocalDirectory(directory) else { continue }
            let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
            guard seen.insert(sessions.standardizedFileURL.path).inserted else { continue }
            roots.append(sessions)
        }
        return roots
    }

    /// Walks each root newest transcript first, reading only bytes appended
    /// since the last refresh and stopping when the budget runs out.
    ///
    /// Roots can overlap — two accounts pointed at one home, or `GROK_HOME` set
    /// to the default — so files are deduplicated by cache key the way the
    /// Claude scanner deduplicates its project roots.
    ///
    /// Cache-key dedup only catches the *same* file reached twice. Two distinct
    /// files describing the same session — a sync conflict copy, a restored
    /// backup — are caught one level down, by folding each file's tally against
    /// the events already counted.
    nonisolated static func scanRoots(
        _ roots: [URL],
        session: CostScanSession
    ) -> ScanWindows<CostScanWindowContext> {
        var windows = Self.scanWindows(cutoff: session.cutoff, hourlyCutoff: session.hourlyCutoff)
        var coverage = CostScanCorpusCoverage()

        for root in roots {
            guard CostScanFileSystem.isLocalDirectory(root) else { continue }
            let listing = CostScanCorpus.listing(
                in: root,
                modifiedSince: session.listingCutoff,
                fileNames: ["updates.jsonl"]
            )
            coverage.add(listing)
            session.noteListing(listing)

            for file in listing.files {
                guard coverage.keep(file.cacheKey) else { continue }
                guard let totals = Self.totals(for: file, session: session) else { continue }
                session.noteProcessedFile()
                guard Self.fold(totals, into: &windows) else {
                    // This file shares only *some* of its events with one
                    // already folded in — a stale copy holding a prefix of the
                    // live session. Aggregates cannot be de-overlapped after
                    // the fact, so it goes back through the event-level path,
                    // where `apply` drops each duplicate against `eventKeys`.
                    Self.foldByEvent(file, session: session, windows: &windows)
                    continue
                }
            }
        }

        session.retain(coverage: coverage, provider: .grok)
        return windows
    }

    /// Adds one file's tally to the shared windows.
    ///
    /// - Returns: `false` when the file's events partly overlap what is already
    ///   counted, which no aggregate merge can resolve — the caller has to
    ///   re-read that file event by event.
    nonisolated private static func fold(
        _ totals: GrokFileTotals,
        into windows: inout ScanWindows<CostScanWindowContext>
    ) -> Bool {
        // Period keys are a subset of lifetime keys by construction (every
        // in-window event is also a lifetime event), so the lifetime test
        // answers for both windows.
        let keys = totals.lifetime.eventKeys
        if keys.isDisjoint(with: windows.lifetime.eventKeys) {
            windows.period.merge(totals.period)
            windows.lifetime.merge(totals.lifetime)
            return true
        }
        // Every event is already counted: a duplicated session with nothing new.
        return keys.isSubset(of: windows.lifetime.eventKeys)
    }

    /// Streams one file straight into the shared windows, under the same budget
    /// every other read answers to.
    ///
    /// The per-file cache is deliberately left alone. This read starts at byte
    /// zero and produces no tally of its own, so there is nothing here a later
    /// slice could resume from — the record `totals(for:session:)` already
    /// committed stays the file's cached state.
    nonisolated private static func foldByEvent(
        _ file: CostScanFile,
        session: CostScanSession,
        windows: inout ScanWindows<CostScanWindowContext>
    ) {
        let allowance = session.budget.allowance
        guard allowance > 0 else {
            session.noteDeferred(.grok)
            return
        }

        let attribution = Self.attribution(for: file.url)
        let calendar = Calendar.current
        var truncation = CostScanTruncationTally()
        var request = FileLineReadRequest()
        request.maxBytes = allowance

        let read = FileLineReader.readLines(in: file.url, request: request) { readerLine, _ in
            // swiftlint:disable:next contains_over_range_nil_comparison
            guard readerLine.bytes.range(of: Self.turnCompletedMarker) != nil else { return }
            let event = Self.usageEvent(from: readerLine.bytes, attribution: attribution)
            truncation.note(readerLine, recovered: event != nil)
            guard let event else { return }
            Self.apply(event, windows: &windows, calendar: calendar)
        }
        truncation.log(url: file.url)

        guard let read else { return }
        session.budget.consume(read.bytesRead)
        if !read.reachedEndOfFile { session.noteDeferred(.grok) }
    }

    /// The window's totals as a published cost row plus its daily rows.
    ///
    /// Unlike the Codex counterpart this neither subtracts `cacheRead` from
    /// `input` nor adds `reasoning` to `output`: Grok nests both inside the
    /// figures it reports, so `apply` already unpacked them at ingest. Doing it
    /// again here would bill the cached prefix twice and double-count reasoning.
    ///
    /// Pricing is all-zero rather than a Grok rate card. Every record carries
    /// its own cost, so the only totals that reach the fallback are ones Grok
    /// itself billed at $0 — which is the right answer for them.
    nonisolated static func makeCost(
        from context: CostScanWindowContext
    ) -> (TokenCost, [DailyTokenUsage], [HourlyTokenUsage])? {
        let totals = context.totals
        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        let pricing = TokenPricing(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)

        return (TokenCost(
            provider: .grok,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheCreationTokens: 0,
            cacheReadTokens: totals.cacheRead,
            estimatedCostUSD: totals.estimatedCostUSD,
            sessionCount: context.sessionIDs.count,
            periodStart: context.earliestDate,
            periodEnd: context.latestDate,
            modelBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: context.modelTotals,
                provider: .grok,
                pricing: pricing
            ),
            originBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: context.originTotals,
                provider: .grok,
                pricing: pricing
            ),
            projectBreakdowns: TokenUsageAggregator.makeProjectBreakdowns(
                from: context.projectTotals,
                modelsByProject: context.projectModelTotals,
                provider: .grok,
                pricing: pricing
            )
        ), TokenUsageAggregator.makeDailyUsage(
            from: context.dailyTotals,
            provider: .grok,
            pricing: pricing,
            modelsByDay: context.dailyModelTotals,
            projectsByDay: context.dailyProjectTotals,
            projectModelsByDay: context.dailyProjectModelTotals
        ), TokenUsageAggregator.makeHourlyUsage(
            from: context.hourlyTotals,
            provider: .grok,
            pricing: pricing
        ))
    }

    /// One `updates.jsonl`'s isolated tally: cached, resumed, or skipped.
    ///
    /// Parsing into the file's *own* windows rather than straight into the
    /// shared ones is what makes the result cacheable — a per-file tally stays
    /// valid no matter which other files a later refresh happens to read.
    ///
    /// - Returns: `nil` when the file has never been read and there was no
    ///   budget left to start it.
    nonisolated private static func totals(
        for file: CostScanFile,
        session: CostScanSession
    ) -> GrokFileTotals? {
        let record = Self.resumableRecord(for: file, session: session)

        // Nothing appended since the last pass.
        if let record, record.isComplete, record.stamp.matches(file.stamp) {
            return record.payload
        }

        let allowance = session.budget.allowance
        guard allowance > 0 else {
            session.noteDeferred(.grok)
            return record?.payload
        }

        var payload = record?.payload ?? GrokFileTotals(cutoff: session.cutoff)
        var windows = ScanWindows(
            period: payload.period,
            lifetime: payload.lifetime,
            cutoff: session.cutoff,
            hourlyCutoff: session.hourlyCutoff
        )
        let attribution = Self.attribution(for: file.url)
        let calendar = Calendar.current
        var truncation = CostScanTruncationTally()

        var request = FileLineReadRequest()
        request.startOffset = record?.offset ?? 0
        request.maxBytes = allowance

        let read = FileLineReader.readLines(in: file.url, request: request) { readerLine, _ in
            // swiftlint:disable:next contains_over_range_nil_comparison
            guard readerLine.bytes.range(of: Self.turnCompletedMarker) != nil else { return }
            let event = Self.usageEvent(from: readerLine.bytes, attribution: attribution)
            // A `turn_completed` envelope carries no message content, so it is
            // orders of magnitude below the reader's line cap. One that arrives
            // truncated anyway is a genuinely damaged file — noted for the log,
            // never salvaged into a half-read token count.
            truncation.note(readerLine, recovered: event != nil)
            guard let event else { return }
            Self.apply(event, windows: &windows, calendar: calendar)
        }
        truncation.log(url: file.url)

        guard let read else { return record?.payload }
        session.budget.consume(read.bytesRead)
        if !read.reachedEndOfFile { session.noteDeferred(.grok) }

        payload.period = windows.period
        payload.lifetime = windows.lifetime

        session.setRecord(
            CostScanFileRecord(
                offset: read.committedOffset,
                stamp: file.stamp,
                cutoff: session.cutoff,
                hourlyCutoff: session.hourlyCutoff,
                isComplete: read.reachedEndOfFile,
                payload: payload
            ),
            for: file.cacheKey,
            provider: .grok
        )
        return payload
    }

    /// The cached entry to resume from, rebased onto this refresh's cutoff.
    ///
    /// - Returns: `nil` when the file has to be re-read from byte zero.
    nonisolated private static func resumableRecord(
        for file: CostScanFile,
        session: CostScanSession
    ) -> CostScanFileRecord<GrokFileTotals>? {
        guard var record = CostScanResumption.resumableRecord(
            existing: session.record(for: file.cacheKey, provider: .grok),
            file: file,
            cutoff: session.cutoff,
            rebase: { payload, cutoff in payload.rebasePeriod(to: cutoff) }
        ) else { return nil }
        guard record.hourlyCutoff <= session.hourlyCutoff else { return nil }
        if record.hourlyCutoff < session.hourlyCutoff {
            record.payload.period.hourlyTotals = record.payload.period.hourlyTotals.filter {
                $0.key >= session.hourlyCutoff
            }
            record.payload.lifetime.hourlyTotals = record.payload.lifetime.hourlyTotals.filter {
                $0.key >= session.hourlyCutoff
            }
            record.hourlyCutoff = session.hourlyCutoff
        }
        return record
    }

    /// Project and fallback session identity, both derived from where the file
    /// lives: `<root>/<percent-encoded project path>/<session uuid>/updates.jsonl`.
    ///
    /// Resolved once per file rather than per line — neither can change part-way
    /// through a file, and percent-decoding is not free.
    nonisolated private static func attribution(for fileURL: URL) -> GrokUsageAttribution {
        let sessionDirectory = fileURL.deletingLastPathComponent()
        let projectDirectory = sessionDirectory.deletingLastPathComponent()
        return GrokUsageAttribution(
            projectID: CostProjectAttribution.grokProjectID(
                encodedDirectoryName: projectDirectory.lastPathComponent
            ),
            fallbackSessionID: sessionDirectory.lastPathComponent
        )
    }

    /// Whole milliseconds since the epoch, or `nil` when the value cannot be
    /// expressed as one. `Int(_:)` traps on a `Double` outside `Int`'s range and
    /// `isFinite` does not rule that out — `1e300` is finite, and its
    /// millisecond value (~1e303) crashed the scan on the way into the dedup
    /// key. Unlike Codex, whose timestamps arrive as bounded ISO-8601 strings,
    /// Grok logs a raw JSON number, so any file on disk can carry one.
    nonisolated private static func millisecondsSinceEpoch(_ seconds: Double) -> Int? {
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int.min),
              milliseconds < Double(Int.max) else { return nil }
        return Int(milliseconds)
    }

    /// One `turn_completed` line's usage, or `nil` for every other line.
    ///
    /// Tolerant on the envelope, strict on the numbers: the method name is
    /// matched by suffix because Grok writes the same update under both
    /// `session/update` and a vendor-prefixed `_x.ai/session/update`, while a
    /// non-numeric `timestamp` drops the record rather than fabricating a 1970
    /// date that would land in the lifetime window. A numeric timestamp too
    /// large to express in whole milliseconds is dropped for the same reason:
    /// it is corrupt, and letting it through would put an absurd date through
    /// `startOfDay` and the window bounds.
    nonisolated private static func usageEvent(
        from line: Data,
        attribution: GrokUsageAttribution
    ) -> GrokUsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let envelope = object as? [String: Any],
              let method = envelope["method"] as? String,
              method.hasSuffix("session/update"),
              let seconds = (envelope["timestamp"] as? NSNumber)?.doubleValue,
              Self.millisecondsSinceEpoch(seconds) != nil,
              let params = envelope["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any] else { return nil }

        let input = CostScanValues.int(usage["inputTokens"])
        let cached = CostScanValues.int(usage["cachedReadTokens"])
        let output = CostScanValues.int(usage["outputTokens"])
        let reasoning = CostScanValues.int(usage["reasoningTokens"])
        guard input > 0 || output > 0 || cached > 0 else { return nil }

        return GrokUsageEvent(
            timestamp: Date(timeIntervalSince1970: seconds),
            sessionID: (params["sessionId"] as? String) ?? attribution.fallbackSessionID,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            ticks: CostScanValues.int(usage["costUsdTicks"]),
            model: Self.dominantModel(in: usage["modelUsage"]),
            projectID: attribution.projectID
        )
    }

    /// The model a turn is attributed to.
    ///
    /// Every observed record carries exactly one entry. A turn that routed
    /// across models is credited to whichever spent the most rather than split,
    /// because the headline totals come from the turn's own `usage` block —
    /// apportioning them by a second set of figures would let the breakdowns
    /// disagree with the total they sum to.
    nonisolated private static func dominantModel(in raw: Any?) -> String? {
        guard let models = raw as? [String: Any], !models.isEmpty else { return nil }

        // A plain loop rather than `map`/`max(by:)`: dictionary order is not
        // stable, so the name tie-break is what keeps a two-model turn from
        // landing under a different heading on each refresh.
        var best: (name: String, ticks: Int)?
        for (name, entry) in models {
            let ticks = CostScanValues.int((entry as? [String: Any])?["costUsdTicks"])
            guard let current = best else {
                best = (name, ticks)
                continue
            }
            if ticks > current.ticks || (ticks == current.ticks && name < current.name) {
                best = (name, ticks)
            }
        }
        return best?.name
    }

    /// Folds one usage record into both windows.
    ///
    /// Records are per-turn increments, not running totals — verified
    /// non-monotonic within a single session on disk — so they are summed.
    /// The dedup key is what keeps a re-logged turn from being billed twice;
    /// it carries the session ID, so no two files can collide.
    ///
    /// `calendar` is passed in rather than resolved here: resolving the current
    /// calendar is not free, and it cannot change part-way through a scan.
    nonisolated private static func apply(
        _ event: GrokUsageEvent,
        windows: inout ScanWindows<CostScanWindowContext>,
        calendar: Calendar
    ) {
        let timestamp = event.timestamp
        let sessionID = event.sessionID
        // Grok nests both figures: `cachedReadTokens <= inputTokens` and
        // `reasoningTokens < outputTokens` in every observed record, with
        // `totalTokens == inputTokens + outputTokens` exactly. Unpacking here —
        // rather than in `makeCost` — means every downstream consumer, including
        // the shared aggregator, sees the same already-correct figures.
        let freshInput = max(0, event.input - event.cached)
        let cost = Double(event.ticks) * Self.usdPerCostTick

        // Whole-millisecond precision, matching the Codex key, so equivalent
        // records produce a stable string rather than a formatted Double.
        // Parsing already rejected timestamps that cannot be expressed this way;
        // converting through the same helper keeps the conversion trap-free
        // rather than relying on that guarantee holding at a distance.
        guard let timestampMillis = Self.millisecondsSinceEpoch(timestamp.timeIntervalSince1970) else { return }
        let key = """
            \(timestampMillis)-\(sessionID)-\(event.input)-\(event.cached)-\
            \(event.output)-\(event.reasoning)-\(event.ticks)
            """
        let keys = CostScanEventKeys(
            day: calendar.startOfDay(for: timestamp),
            hour: timestamp >= windows.hourlyCutoff
                ? CostScanHourBucket.start(for: timestamp, calendar: calendar)
                : nil,
            model: CostScanValues.displayModelName(event.model),
            origin: CostScanValues.displayOriginName(Self.originName),
            project: event.projectID
        )
        let breakdown = CostScanEventTotals(
            input: freshInput,
            output: event.output,
            cacheCreation: 0,
            cacheRead: event.cached,
            estimatedCostUSD: cost
        )

        // No `pricing.record`: nothing here was priced from a local table, so
        // there is no provenance to report and no table gap to warn about.
        windows.update(at: timestamp) { context in
            guard context.eventKeys.insert(key).inserted else { return }

            context.sessionIDs.insert(sessionID)
            context.totals.add(
                input: freshInput,
                output: event.output,
                cacheCreation: 0,
                cacheRead: event.cached,
                estimatedCostUSD: cost
            )
            context.record(breakdown, at: keys)
            if timestamp < context.earliestDate { context.earliestDate = timestamp }
            if timestamp > context.latestDate { context.latestDate = timestamp }
        }
    }
}

/// Where a Grok record's spend belongs, derived once per file from its path.
nonisolated struct GrokUsageAttribution: Sendable {
    let projectID: String

    /// Used when the envelope omits `params.sessionId`. The session directory is
    /// named after the session, so it is the same identity by another route.
    let fallbackSessionID: String
}

/// One `turn_completed` record's usage, as written.
///
/// Deliberately raw: `input` still includes `cached` and `output` still includes
/// `reasoning`, exactly as Grok reported them, so the dedup key is computed over
/// the figures on disk rather than over a derived view of them.
nonisolated struct GrokUsageEvent: Sendable {
    let timestamp: Date
    let sessionID: String
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int

    /// Cost as Grok billed it, in `costUsdTicks`. See
    /// `GrokCostScanner.usdPerCostTick` for the scale and how it was pinned.
    let ticks: Int

    let model: String?
    let projectID: String
}
