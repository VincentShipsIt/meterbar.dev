import Foundation
import MeterBarShared
import os
import SQLite3

/// Reads Codex CLI rollouts and the CLI's SQLite log database and turns them
/// into cost totals. Split out of `CostTracker` (audit C1d) so rollout
/// attribution and log parsing are testable without publishing a summary.
enum CodexCostScanner {
    // Cached regexes. The scan parses tens of thousands of log lines, so
    // allocating an NSRegularExpression per call was a measurable hot-path
    // cost. Date parsing shares the cached FlexibleISO8601 formatters.
    nonisolated private static let logValueRegexes: [String: NSRegularExpression] = {
        let keys = [
            "event.timestamp", "input_token_count", "output_token_count",
            "cached_token_count", "reasoning_token_count", "conversation.id",
            "thread.id", "model", "slug", "originator"
        ]
        var result: [String: NSRegularExpression] = [:]
        for key in keys {
            let pattern = NSRegularExpression.escapedPattern(for: key) + #"=([^\s}]+)"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result[key] = regex
            }
        }
        return result
    }()

    /// Seeds both windows the way the two separate scans used to seed themselves:
    /// `earliestDate` starts at now and only decreases, `latestDate` starts at the
    /// window floor (the cutoff for the period, `.distantPast` for lifetime) and
    /// only increases.
    nonisolated static func scanWindows(cutoff: Date) -> ScanWindows<CodexScanContext> {
        ScanWindows(
            period: CodexScanContext(earliestDate: Date(), latestDate: cutoff),
            lifetime: CodexScanContext(earliestDate: Date(), latestDate: .distantPast),
            cutoff: cutoff
        )
    }

    /// The rate card in effect for `model` at `timestamp`. Every Codex price
    /// resolution goes through the shared table so the app, the widget, and the
    /// CLI cannot drift apart (issues #130 and #339).
    nonisolated static func pricing(for model: String?, at timestamp: Date = Date()) -> TokenPricing {
        ModelPricing.codex(for: model, at: timestamp)
    }

    /// Same lookup, but keeping the entry's verification date and whether the
    /// event predates the table so the scan can report what it priced with.
    nonisolated static func resolvePricing(for model: String?, at timestamp: Date) -> ResolvedPricing {
        ModelPricing.resolveCodex(for: model, at: timestamp)
    }

    /// `pricingAt` is the seam that lets a test drive a dated schedule; the
    /// default is the shared table every caller ships with.
    nonisolated static func makeCost(
        from context: CodexScanContext,
        pricingAt: @escaping (String?, Date) -> TokenPricing = ModelPricing.codex(for:at:)
    ) -> (TokenCost, [DailyTokenUsage])? {
        let totals = context.totals
        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        // A window aggregates many events, so it has no single event time; its
        // newest event is the closest defensible stand-in, and it is already
        // what the window reports as `periodEnd`. Daily rows resolve per day.
        let windowEnd = context.latestDate
        let pricing = pricingAt(nil, windowEnd)
        let billableInput = max(0, totals.input - totals.cacheRead)
        let output = totals.output + totals.reasoning
        // Prefer the sum of per-event costs, each priced at its own timestamp's
        // rate; fall back to the rate in effect when the tokens were recorded
        // only for totals that carry no per-event cost (issue #339).
        let fallbackCost = TokenCostMath.calculateCost(
            input: billableInput,
            output: output,
            cacheCreation: 0,
            cacheRead: totals.cacheRead,
            pricing: pricing
        )
        let cost = totals.estimatedCostUSD > 0 ? totals.estimatedCostUSD : fallbackCost

        return (TokenCost(
            provider: .codexCli,
            inputTokens: billableInput,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: totals.cacheRead,
            estimatedCostUSD: cost,
            sessionCount: context.sessionIDs.count,
            periodStart: context.earliestDate,
            periodEnd: context.latestDate,
            modelBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: context.modelTotals,
                provider: .codexCli,
                pricing: pricing,
                pricingForName: { pricingAt($0, windowEnd) }
            ),
            originBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: context.originTotals,
                provider: .codexCli,
                pricing: pricing
            ),
            projectBreakdowns: TokenUsageAggregator.makeProjectBreakdowns(
                from: context.projectTotals,
                modelsByProject: context.projectModelTotals,
                provider: .codexCli,
                pricing: pricing,
                pricingForName: { pricingAt($0, windowEnd) }
            )
        ), TokenUsageAggregator.makeDailyUsage(
            from: context.dailyTotals,
            provider: .codexCli,
            pricing: pricing,
            modelsByDay: context.dailyModelTotals,
            projectsByDay: context.dailyProjectTotals,
            projectModelsByDay: context.dailyProjectModelTotals,
            pricingAt: pricingAt
        ))
    }

    /// Directories holding Codex rollout `.jsonl` files. Codex only moves a
    /// rollout into `archived_sessions` when the session closes, so scanning
    /// that alone silently dropped every still-open session — which is most of
    /// the recent days on an actively used machine.
    nonisolated static func rolloutDirectories(in codexDir: URL) -> [URL] {
        [
            codexDir.appendingPathComponent("archived_sessions", isDirectory: true),
            codexDir.appendingPathComponent("sessions", isDirectory: true)
        ]
    }

    /// The conversation a rollout belongs to, taken from its file name.
    ///
    /// Codex names rollouts `rollout-<ISO timestamp>-<session uuid>.jsonl` and
    /// keeps the whole name when it archives one, so the trailing UUID is what
    /// ties the copy in `archived_sessions/` to the one still being written in
    /// `sessions/`. Anything that does not end in a UUID — an older layout, a
    /// hand-placed file — is its own session under its full stem.
    nonisolated static func rolloutSessionID(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let uuidLength = 36
        guard stem.count > uuidLength else { return stem }
        let suffix = String(stem.suffix(uuidLength))
        guard UUID(uuidString: suffix) != nil else { return stem }
        return suffix.lowercased()
    }

    /// One file per conversation, in the order the scan should read them.
    ///
    /// A session that exists in both `sessions/` and `archived_sessions/` is the
    /// same bytes twice. Reading both and reconciling them afterwards is what
    /// used to force a whole rollout back through an unbudgeted re-parse on
    /// every slice; picking a copy up front removes that case instead of paying
    /// for it. The larger copy wins because archiving happens while a session is
    /// still live, so the archived snapshot can be short — and a tie goes to the
    /// copy found last, which is the one under `sessions/` that may still grow.
    ///
    /// The result is re-sorted rather than returned in discovery order.
    /// `CostScanCorpus.transcripts` only orders within one directory, and
    /// `archived_sessions` is enumerated first, so discovery order would put
    /// every archived rollout ahead of every live one — handing a slice's whole
    /// budget to the oldest conversations on disk. The comparator is the
    /// corpus's own, so a rollout's position does not depend on which directory
    /// its surviving copy came from.
    nonisolated static func distinctRollouts(in directories: [URL]) -> [CostScanFile] {
        var chosen: [String: CostScanFile] = [:]
        var seen: Set<String> = []

        for directory in directories {
            guard CostScanFileSystem.isLocalDirectory(directory) else { continue }

            for file in CostScanCorpus.transcripts(in: directory) {
                guard seen.insert(file.cacheKey).inserted else { continue }
                let sessionID = Self.rolloutSessionID(for: file.url)
                guard let incumbent = chosen[sessionID] else {
                    chosen[sessionID] = file
                    continue
                }
                if file.size >= incumbent.size { chosen[sessionID] = file }
            }
        }
        return chosen.values.sorted {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
        }
    }

    // swiftlint:disable contains_over_range_nil_comparison
    /// The byte-level equivalent of the old `line.contains("\"token_count\"")`
    /// prefilter. Rollout files are mostly non-usage events, so skipping
    /// `JSONSerialization` on them is what keeps the scan cheap.
    /// Generic `Data.contains(_:)` runs near 3 MB/s; `range(of:)` reaches 1.8 GB/s, which slice budgets require.
    nonisolated private static let tokenCountMarker = Data("\"token_count\"".utf8)

    /// Same prefilter for the two events that carry the attribution a
    /// `token_count` line lacks. Cheap enough to run on every non-usage line.
    nonisolated private static let turnContextMarker = Data("\"turn_context\"".utf8)
    nonisolated private static let sessionMetaMarker = Data("\"session_meta\"".utf8)

    /// Turns one rollout into the usage events it contributes, in the order the
    /// scan applies them.
    ///
    /// Internal (not private) so the rollout parsing — the Codex counterpart to
    /// `parseSessionFile`, and where CLI-vs-app cost divergence hides — can be
    /// fixture-tested against a temp directory.
    ///
    /// A `token_count` event names neither the model nor the front end, so the
    /// scan streams each file in order and carries the last `turn_context`
    /// model and the opening `session_meta` originator forward. Attribution is
    /// per file: state resets on every rollout, since attribution carried
    /// across rollouts would label one session's spend with another's model.
    nonisolated static func parseRollout(at fileURL: URL) -> [CodexUsageEvent] {
        var events: [CodexUsageEvent] = []
        var rollout = CodexRolloutContext()
        // Codex emits a session's opening `token_count` events *before* its
        // first `turn_context`, so forward-only attribution orphaned them even
        // though the same file names the model seconds later. Park them here
        // instead and back-fill once the file declares a model. Per file, like
        // the rollout context: a sibling rollout's model must never name events
        // this file left unexplained.
        var deferred: [CodexDeferredUsage] = []
        var truncation = CostScanTruncationTally()

        FileLineReader.forEachLine(in: fileURL) { readerLine in
            let line = readerLine.bytes
            guard line.range(of: Self.tokenCountMarker) != nil else {
                Self.updateRolloutContext(&rollout, from: line)
                // Reaches back only as far as the *first* model the file
                // declares — a later mid-session switch must not relabel the
                // events that preceded it.
                if let model = rollout.turnModel ?? rollout.sessionModel {
                    Self.flushDeferred(&deferred, modelName: model, into: &events)
                }
                return
            }
            // Counted only past this guard, and so only for usage lines. Codex
            // rollouts are full of oversized `function_call_output` records that
            // carry no accounting; calling their truncation a dropped record
            // would bury the one case that costs tokens under thousands that
            // cost nothing.
            let produced = events.count + deferred.count
            Self.addTokenCountLine(
                line,
                fileURL: fileURL,
                rollout: rollout,
                deferred: &deferred,
                events: &events
            )
            truncation.note(readerLine, recovered: events.count + deferred.count > produced)
        }
        // Whatever the file never explained is genuinely unattributed.
        Self.flushDeferred(&deferred, modelName: nil, into: &events)
        truncation.log(url: fileURL)
        return events
    }

    /// Streams one rollout end to end into `windows`.
    ///
    /// Serial by construction. Unlike Claude's per-file dedup,
    /// `CodexScanContext.eventKeys` spans every rollout *and* the SQLite log,
    /// first event wins — so the order files reach here is the order that
    /// decides the answer.
    ///
    /// Internal (not private) so a fixture scan can drive a whole directory
    /// through it.
    nonisolated static func parseRollout(
        at fileURL: URL,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        let calendar = Calendar.current
        for event in Self.parseRollout(at: fileURL) {
            Self.apply(event, windows: &windows, calendar: calendar)
        }
    }

    // MARK: - Budgeted, resumable scan

    /// Rollouts and the flat SQLite log, read under `session`'s budget.
    nonisolated static func scanSessions(session: CostScanSession) -> ScanWindows<CodexScanContext> {
        let codexDir = URL(fileURLWithPath: CodexHomeDirectory.path(), isDirectory: true)
        var windows = Self.scanRollouts(
            directories: Self.rolloutDirectories(in: codexDir),
            session: session
        )
        // Rollouts are the authoritative lifetime corpus. The SQLite store is
        // only a recent-session fallback, and it must not escape the slice
        // budget: a modern Codex database can be multiple gigabytes even when
        // it contains no usage telemetry at all. Read it once, after the
        // resumable rollout pass has completed, instead of once per slice.
        if session.isComplete {
            Self.scanSQLiteLogs(
                database: codexDir.appendingPathComponent("logs_2.sqlite"),
                since: session.cutoff,
                windows: &windows
            )
        }
        return windows
    }

    /// Walks `directories` newest rollout first, reading only bytes appended
    /// since the last refresh and stopping when the budget runs out.
    nonisolated static func scanRollouts(
        directories: [URL],
        session: CostScanSession
    ) -> ScanWindows<CodexScanContext> {
        var windows = Self.scanWindows(cutoff: session.cutoff)
        let files = Self.distinctRollouts(in: directories)
        var live: Set<String> = []

        for file in files {
            live.insert(file.cacheKey)
            guard let totals = Self.totals(for: file, session: session) else { continue }
            guard Self.fold(totals, into: &windows) else {
                // This rollout shares only *some* of its events with one already
                // folded in. Aggregates cannot be de-overlapped after the fact,
                // so the file goes back through the event-level path, where
                // `apply` drops each duplicate against the window's `eventKeys`.
                //
                // Rollouts duplicated across `sessions/` and
                // `archived_sessions/` no longer reach here at all — only one
                // copy is ever read. What is left is two genuinely different
                // conversations that recorded the same event, which still costs
                // a re-read on every slice; it is budgeted and cancellable, but
                // it is not cached, because a tally that overlaps the shared
                // windows is not one a later refresh can reuse.
                Self.foldByEvent(file, session: session, windows: &windows)
                continue
            }
        }

        session.retainCodex(keys: live)
        return windows
    }

    /// One rollout's isolated tally: cached, resumed, or skipped.
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
    ) -> CodexFileTotals? {
        let record = Self.resumableRecord(for: file, session: session)

        // Nothing appended since the last pass.
        if let record, record.isComplete, record.stamp.matches(file.stamp) {
            return record.payload
        }

        let allowance = session.budget.allowance
        guard allowance > 0 else {
            session.noteDeferred(.codex)
            return record?.payload
        }

        var payload = record?.payload ?? CodexFileTotals(cutoff: session.cutoff)
        var windows = ScanWindows(
            period: payload.period,
            lifetime: payload.lifetime,
            cutoff: session.cutoff
        )
        var rollout = payload.rollout
        var deferred: [CodexDeferredUsage] = []
        var deferredOffset: UInt64?
        let calendar = Calendar.current
        var truncation = CostScanTruncationTally()

        var request = FileLineReadRequest()
        request.startOffset = record?.offset ?? 0
        request.maxBytes = allowance

        let read = FileLineReader.readLines(in: file.url, request: request) { readerLine, offset in
            let line = readerLine.bytes
            guard line.range(of: Self.tokenCountMarker) != nil else {
                Self.updateRolloutContext(&rollout, from: line)
                if let model = rollout.turnModel ?? rollout.sessionModel {
                    Self.flushDeferred(
                        &deferred,
                        modelName: model,
                        windows: &windows,
                        calendar: calendar
                    )
                    deferredOffset = nil
                }
                return
            }
            let parked = deferred.count
            let counted = windows.lifetime.eventKeys.count
            Self.addTokenCountLine(
                line,
                fileURL: file.url,
                rollout: rollout,
                deferred: &deferred,
                windows: &windows,
                calendar: calendar
            )
            truncation.note(
                readerLine,
                recovered: deferred.count > parked || windows.lifetime.eventKeys.count > counted
            )
            if deferred.count > parked, deferredOffset == nil {
                deferredOffset = offset
            }
        }
        truncation.log(url: file.url)

        guard let read else { return record?.payload }
        session.budget.consume(read.bytesRead)

        var committed = read.committedOffset
        if read.reachedEndOfFile {
            Self.flushDeferred(&deferred, modelName: nil, windows: &windows, calendar: calendar)
        } else {
            session.noteDeferred(.codex)
            if let deferredOffset {
                // Events still waiting on a model the *next* slice may yet
                // declare. Rolling the offset back re-reads them rather than
                // stranding them as unattributed; every event already counted
                // is re-read too, and `eventKeys` discards it as the duplicate
                // it is.
                committed = deferredOffset
            }
        }

        payload.period = windows.period
        payload.lifetime = windows.lifetime
        payload.rollout = rollout

        session.setCodexRecord(
            CostScanFileRecord(
                offset: committed,
                stamp: file.stamp,
                cutoff: session.cutoff,
                isComplete: read.reachedEndOfFile,
                payload: payload
            ),
            for: file.cacheKey
        )
        return payload
    }

    /// Streams one rollout straight into the shared windows, under the same
    /// budget every other read answers to.
    ///
    /// The per-file cache is deliberately left alone. This read starts at byte
    /// zero and produces no tally of its own, so there is nothing here a later
    /// slice could resume from — the record `totals(for:session:)` already
    /// committed stays the file's cached state.
    nonisolated private static func foldByEvent(
        _ file: CostScanFile,
        session: CostScanSession,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        let allowance = session.budget.allowance
        guard allowance > 0 else {
            session.noteDeferred(.codex)
            return
        }

        let calendar = Calendar.current
        var rollout = CodexRolloutContext()
        var deferred: [CodexDeferredUsage] = []
        var truncation = CostScanTruncationTally()
        var request = FileLineReadRequest()
        request.maxBytes = allowance

        let read = FileLineReader.readLines(in: file.url, request: request) { readerLine, _ in
            let line = readerLine.bytes
            guard line.range(of: Self.tokenCountMarker) != nil else {
                Self.updateRolloutContext(&rollout, from: line)
                if let model = rollout.turnModel ?? rollout.sessionModel {
                    Self.flushDeferred(
                        &deferred,
                        modelName: model,
                        windows: &windows,
                        calendar: calendar
                    )
                }
                return
            }
            let parked = deferred.count
            let counted = windows.lifetime.eventKeys.count
            Self.addTokenCountLine(
                line,
                fileURL: file.url,
                rollout: rollout,
                deferred: &deferred,
                windows: &windows,
                calendar: calendar
            )
            truncation.note(
                readerLine,
                recovered: deferred.count > parked || windows.lifetime.eventKeys.count > counted
            )
        }
        truncation.log(url: file.url)

        guard let read else { return }
        session.budget.consume(read.bytesRead)

        if read.reachedEndOfFile {
            Self.flushDeferred(&deferred, modelName: nil, windows: &windows, calendar: calendar)
        } else {
            // Whatever is still parked belongs to a model the unread remainder
            // may yet name. Dropping it as unattributed would be worse than
            // letting the next slice read the file again.
            session.noteDeferred(.codex)
        }
    }

    /// Adds one rollout's tally to the shared windows.
    ///
    /// - Returns: `false` when the file's events partly overlap what is already
    ///   counted, which no aggregate merge can resolve — the caller has to
    ///   re-read that file event by event.
    nonisolated private static func fold(
        _ totals: CodexFileTotals,
        into windows: inout ScanWindows<CodexScanContext>
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
        // Every event is already counted: a duplicated rollout with nothing new.
        return keys.isSubset(of: windows.lifetime.eventKeys)
    }

    /// The cached entry to resume from, rebased onto this refresh's cutoff.
    ///
    /// - Returns: `nil` when the rollout has to be re-read from byte zero.
    nonisolated private static func resumableRecord(
        for file: CostScanFile,
        session: CostScanSession
    ) -> CostScanFileRecord<CodexFileTotals>? {
        guard var record = session.codexRecord(for: file.cacheKey) else { return nil }
        guard record.offset <= UInt64(file.size) else { return nil }
        if record.isComplete, record.stamp.size == file.size {
            guard record.stamp.matches(file.stamp) else { return nil }
        } else {
            guard record.stamp.isSameFile(as: file.stamp),
                  file.size >= record.stamp.size else { return nil }
        }
        guard record.cutoff != session.cutoff else { return record }

        let lifetime = record.payload.lifetime
        if lifetime.eventKeys.isEmpty || lifetime.latestDate < session.cutoff {
            // Every event predates the new window.
            record.payload.period = CodexScanContext(
                earliestDate: Date(),
                latestDate: session.cutoff
            )
        } else if lifetime.earliestDate >= session.cutoff {
            // Every event falls inside it.
            record.payload.period = lifetime
        } else {
            // The rollout straddles the cutoff and only its individual events
            // know where. Only files that actually straddle pay for the window
            // moving.
            return nil
        }
        record.cutoff = session.cutoff
        return record
    }

    /// Picks up the model/originator carried by the non-usage rollout events.
    nonisolated private static func updateRolloutContext(
        _ rollout: inout CodexRolloutContext,
        from line: Data
    ) {
        if line.range(of: Self.turnContextMarker) != nil {
            guard let payload = Self.eventPayload(in: line, type: "turn_context") else { return }
            rollout.turnModel = (payload["model"] as? String) ?? rollout.turnModel
        } else if line.range(of: Self.sessionMetaMarker) != nil {
            guard let payload = Self.eventPayload(in: line, type: "session_meta") else { return }
            // `model` is null on every rollout observed so far, but read it
            // anyway so pre-turn events get named the day Codex populates it.
            rollout.sessionModel = (payload["model"] as? String) ?? rollout.sessionModel
            rollout.originator = (payload["originator"] as? String) ?? rollout.originator
            rollout.cwd = (payload["cwd"] as? String) ?? rollout.cwd
        }
    }
    // swiftlint:enable contains_over_range_nil_comparison

    /// Replays the events parked before the file named a model. Each keeps its
    /// own timestamp, so `ScanWindows.update` still places it on its own day.
    nonisolated private static func flushDeferred(
        _ deferred: inout [CodexDeferredUsage],
        modelName: String?,
        into events: inout [CodexUsageEvent]
    ) {
        guard !deferred.isEmpty else { return }

        for pending in deferred {
            guard let event = Self.makeUsageEvent(
                pending.usage,
                timestamp: pending.timestamp,
                sessionID: pending.sessionID,
                attribution: CodexUsageAttribution(
                    modelName: modelName,
                    originName: pending.originName,
                    projectID: pending.projectID
                )
            ) else { continue }
            events.append(event)
        }
        deferred.removeAll()
    }

    /// Budgeted scans fold each completed line immediately so their cache can
    /// commit progress at a line boundary. Keep that path on the same event
    /// extraction used by the parallel whole-file scan.
    nonisolated private static func flushDeferred(
        _ deferred: inout [CodexDeferredUsage],
        modelName: String?,
        windows: inout ScanWindows<CodexScanContext>,
        calendar: Calendar
    ) {
        var events: [CodexUsageEvent] = []
        Self.flushDeferred(&deferred, modelName: modelName, into: &events)
        for event in events {
            Self.apply(event, windows: &windows, calendar: calendar)
        }
    }

    nonisolated private static func addTokenCountLine(
        _ line: Data,
        fileURL: URL,
        rollout: CodexRolloutContext,
        deferred: inout [CodexDeferredUsage],
        events: inout [CodexUsageEvent]
    ) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestampText = json["timestamp"] as? String,
              let timestamp = FlexibleISO8601.date(from: timestampText),
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = (info["last_token_usage"] ?? info["total_token_usage"]) as? [String: Any] else {
            return
        }

        let sessionID = (((payload["rate_limits"] as? [String: Any])?["conversation_id"] as? String)
            ?? fileURL.deletingPathExtension().lastPathComponent)
        // The event's own model wins when present (older rollouts stamped it
        // there); otherwise fall back to the surrounding rollout context.
        let modelName = Self.modelName(from: info, payload: payload)
            ?? rollout.turnModel
            ?? rollout.sessionModel
        // Origin and project are read now rather than at flush time: they come
        // from `session_meta`, which a rollout always opens with, so the values
        // in hand are already the final ones. Only the model is back-filled.
        let originName = rollout.originator ?? "Codex CLI"
        let projectID = CostProjectAttribution.codexProjectID(cwd: rollout.cwd)

        guard let modelName else {
            deferred.append(CodexDeferredUsage(
                usage: usage,
                timestamp: timestamp,
                sessionID: sessionID,
                originName: originName,
                projectID: projectID
            ))
            return
        }

        guard let event = Self.makeUsageEvent(
            usage,
            timestamp: timestamp,
            sessionID: sessionID,
            attribution: CodexUsageAttribution(
                modelName: modelName,
                originName: originName,
                projectID: projectID
            )
        ) else { return }
        events.append(event)
    }

    nonisolated private static func addTokenCountLine(
        _ line: Data,
        fileURL: URL,
        rollout: CodexRolloutContext,
        deferred: inout [CodexDeferredUsage],
        windows: inout ScanWindows<CodexScanContext>,
        calendar: Calendar
    ) {
        var events: [CodexUsageEvent] = []
        Self.addTokenCountLine(
            line,
            fileURL: fileURL,
            rollout: rollout,
            deferred: &deferred,
            events: &events
        )
        for event in events {
            Self.apply(event, windows: &windows, calendar: calendar)
        }
    }

    nonisolated private static func eventPayload(
        in line: Data,
        type: String
    ) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == type,
              let payload = json["payload"] as? [String: Any] else {
            return nil
        }
        return payload
    }

    nonisolated static func scanSQLiteLogs(
        database: URL,
        since cutoffDate: Date,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        var db: OpaquePointer?
        // SQLite hands back a handle even for most open failures, so the close
        // has to be armed before the status check or the failure path leaks it.
        let openResult = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openResult == SQLITE_OK else { return }

        // `logs_2.sqlite` now stores the complete Codex diagnostic stream, not
        // just the old OpenTelemetry cost rows. Restricting the indexed time
        // range and producer target avoids reading arbitrary prompt/tool bodies
        // merely because they happen to contain one of the parser's key names.
        // Recent SQLite rows are enough here: rollouts above own lifetime
        // history, while this fallback covers a current session before its
        // rollout is visible.
        let sql = """
            SELECT feedback_log_body
                FROM logs
            WHERE ts >= ?
              AND target = 'codex_otel.trace_safe'
              AND (
                    feedback_log_body LIKE '%input_token_count=%'
                 OR feedback_log_body LIKE '%output_token_count=%'
                 OR feedback_log_body LIKE '%cached_token_count=%'
                 OR feedback_log_body LIKE '%reasoning_token_count=%'
              )
              AND feedback_log_body LIKE '%event.timestamp=%'
            ORDER BY ts ASC, ts_nanos ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(cutoffDate.timeIntervalSince1970.rounded(.down)))
        let calendar = Calendar.current

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bodyPointer = sqlite3_column_text(statement, 0) else { continue }
            let body = String(cString: bodyPointer)
            guard let timestamp = Self.logDate(in: body) else { continue }

            let usage: [String: Any] = [
                "input_tokens": Self.logInt("input_token_count", in: body),
                "output_tokens": Self.logInt("output_token_count", in: body),
                "cached_input_tokens": Self.logInt("cached_token_count", in: body),
                "reasoning_output_tokens": Self.logInt("reasoning_token_count", in: body)
            ]
            let sessionID = Self.logValue("conversation.id", in: body)
                ?? Self.logValue("thread.id", in: body)
                ?? "codex"
            guard let event = Self.makeUsageEvent(
                usage,
                timestamp: timestamp,
                sessionID: sessionID,
                attribution: CodexUsageAttribution(
                    modelName: Self.logValue("model", in: body) ?? Self.logValue("slug", in: body),
                    originName: Self.logValue("originator", in: body) ?? "Codex CLI",
                    // The flat SQLite log format carries no cwd/path field at
                    // all (issue #270) — always the explicit unknown bucket,
                    // never a guess.
                    projectID: CostProjectAttribution.unknownProjectID
                )
            ) else { continue }
            // Same `eventKeys` set the rollouts filled, so a turn recorded in
            // both places is still billed once.
            Self.apply(event, windows: &windows, calendar: calendar)
        }
    }

    /// Stays at four named parameters — SwiftLint's `function_parameter_count`
    /// warns at seven and CI lints with `--strict` — because `modelName`/
    /// `originName`/`projectID` are bundled into one `CodexUsageAttribution`
    /// value instead of three separate parameters.
    ///
    /// Pulling the extraction out of `apply` is what lets a rollout be parsed
    /// on a worker thread: `[String: Any]` is not `Sendable` and never leaves
    /// the parse, while `CodexUsageEvent` is a plain value the fold can carry
    /// back to the shared windows.
    nonisolated private static func makeUsageEvent(
        _ usage: [String: Any],
        timestamp: Date,
        sessionID: String,
        attribution: CodexUsageAttribution
    ) -> CodexUsageEvent? {
        let input = CostScanValues.int(usage["input_tokens"])
        let cached = CostScanValues.int(usage["cached_input_tokens"])
        let output = CostScanValues.int(usage["output_tokens"])
        let reasoning = CostScanValues.int(usage["reasoning_output_tokens"])
        guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { return nil }

        return CodexUsageEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            attribution: attribution
        )
    }

    /// Folds one usage event into both windows. Serial by construction: the
    /// dedup below is first-event-wins across every file, so the order events
    /// arrive here is the order that decides the answer.
    ///
    /// `calendar` is passed in rather than resolved here: resolving the current
    /// calendar is not free, and it cannot change part-way through a scan.
    nonisolated private static func apply(
        _ event: CodexUsageEvent,
        windows: inout ScanWindows<CodexScanContext>,
        calendar: Calendar
    ) {
        let timestamp = event.timestamp
        let sessionID = event.sessionID
        let input = event.input
        let cached = event.cached
        let output = event.output
        let reasoning = event.reasoning

        // Use whole-millisecond precision for the dedup key so equivalent events
        // produce a stable, collision-resistant string (raw Double formatting can
        // vary and risks both false matches and false misses).
        let timestampMillis = Int((timestamp.timeIntervalSince1970 * 1000).rounded())
        let key = "\(timestampMillis)-\(sessionID)-\(input)-\(cached)-\(output)-\(reasoning)"
        let keys = CostScanEventKeys(
            day: calendar.startOfDay(for: timestamp),
            model: CostScanValues.displayModelName(event.attribution.modelName),
            origin: CostScanValues.displayOriginName(event.attribution.originName),
            project: event.attribution.projectID
        )

        // Price the event at the rate in effect when it was recorded (issue
        // #339). Codex used to cost the whole window in one shot at today's
        // rate, which could not distinguish a session billed under an older
        // rate card. Cached input is already billed by `cacheRead`, so it is
        // subtracted from the billable input exactly as the aggregate did.
        let resolved = Self.resolvePricing(for: event.attribution.modelName, at: timestamp)
        let eventCost = TokenCostMath.calculateCost(
            input: max(0, input - cached),
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached,
            pricing: resolved.pricing
        )

        // Reasoning tokens are billed as output everywhere except the headline
        // `totals`, which keeps them broken out.
        let breakdown = CostScanEventTotals(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached,
            estimatedCostUSD: eventCost
        )

        // Each window keeps its own `eventKeys`, so an event that lands in both
        // is deduplicated independently in each — exactly what the two separate
        // scans did.
        windows.update(at: timestamp) { context in
            guard context.eventKeys.insert(key).inserted else { return }

            context.sessionIDs.insert(sessionID)
            context.pricing.record(resolved)
            context.totals.add(
                input: input,
                output: output,
                cacheCreation: 0,
                cacheRead: cached,
                reasoning: reasoning,
                estimatedCostUSD: eventCost
            )
            context.record(breakdown, at: keys)
            if timestamp < context.earliestDate { context.earliestDate = timestamp }
            if timestamp > context.latestDate { context.latestDate = timestamp }
        }
    }

    /// Internal (not private) so the attribution precedence can be unit-tested.
    nonisolated static func modelName(from info: [String: Any], payload: [String: Any]) -> String? {
        (info["model"] as? String)
            ?? (info["slug"] as? String)
            ?? (payload["model"] as? String)
            ?? (payload["slug"] as? String)
    }

    /// Internal (not private) so the flat-log parsers can be unit-tested.
    nonisolated static func logDate(in text: String) -> Date? {
        guard let value = Self.logValue("event.timestamp", in: text) else { return nil }
        return FlexibleISO8601.date(from: value)
    }

    nonisolated static func logInt(_ key: String, in text: String) -> Int {
        guard let value = Self.logValue(key, in: text) else { return 0 }
        return Int(value) ?? 0
    }

    nonisolated static func logValue(_ key: String, in text: String) -> String? {
        let regex: NSRegularExpression
        if let cached = Self.logValueRegexes[key] {
            regex = cached
        } else {
            let pattern = NSRegularExpression.escapedPattern(for: key) + #"=([^\s}]+)"#
            guard let built = try? NSRegularExpression(pattern: pattern) else { return nil }
            regex = built
        }

        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

/// Attribution carried forward while streaming a single rollout file. Codex
/// `token_count` events name neither the model nor the front end: the model is
/// declared once per turn in `turn_context`, the front end once per session in
/// `session_meta`. Reset per file so one rollout never labels another's spend.
/// `Codable` because `CodexFileTotals` persists it: a slice that resumes past a
/// rollout's opening `session_meta`/`turn_context` would attribute every
/// remaining event to "unknown" without the labels the previous slice read.
nonisolated struct CodexRolloutContext: Sendable, Codable {
    var turnModel: String?
    var sessionModel: String?
    var originator: String?
    /// Real, unencoded working directory from `session_meta.payload.cwd`
    /// (issue #270) — the non-prompt-content field project attribution is
    /// derived from. `nil` until (or unless) a `session_meta` event supplies it.
    var cwd: String?
}

/// A `token_count` event parked because its rollout has not named a model yet.
///
/// Deliberately not `Sendable`: it carries the raw `[String: Any]` usage
/// payload. It never outlives the single-threaded parse of the file that made
/// it, so it does not need to be.
nonisolated struct CodexDeferredUsage {
    let usage: [String: Any]
    let timestamp: Date
    let sessionID: String
    let originName: String
    let projectID: String
}

/// Bundles the three "who/what/where" labels a single usage event needs so
/// `makeUsageEvent` can stay under SwiftLint's `function_parameter_count` limit
/// (issue #270 added `projectID` as the third label alongside the pre-existing
/// model/origin pair).
nonisolated struct CodexUsageAttribution: Sendable {
    let modelName: String?
    let originName: String?
    let projectID: String
}

/// One usage event, extracted from a rollout line or a SQLite log row and ready
/// to fold into a `CodexScanContext`.
///
/// This is the boundary between the parallel half of the scan and the serial
/// half: rollouts are parsed into these on worker threads, then applied to the
/// shared windows one at a time, in file order. It holds only value types so it
/// can cross that boundary — the raw `[String: Any]` payload it came from stays
/// behind on the worker.
nonisolated struct CodexUsageEvent: Sendable {
    let timestamp: Date
    let sessionID: String
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int
    let attribution: CodexUsageAttribution
}
