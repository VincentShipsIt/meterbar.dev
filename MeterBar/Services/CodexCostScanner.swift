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

    nonisolated static func scanSessions(since cutoffDate: Date) -> ScanWindows<CodexScanContext> {
        let codexDir = URL(fileURLWithPath: CodexHomeDirectory.path(), isDirectory: true)
        let logsDatabase = codexDir.appendingPathComponent("logs_2.sqlite")
        var windows = Self.scanWindows(cutoff: cutoffDate)

        for directory in Self.rolloutDirectories(in: codexDir) {
            Self.scanRollouts(directory: directory, windows: &windows)
        }
        Self.scanSQLiteLogs(database: logsDatabase, windows: &windows)

        return windows
    }

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

    nonisolated static func makeCost(
        from context: CodexScanContext
    ) -> (TokenCost, [DailyTokenUsage])? {
        let totals = context.totals
        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        let pricing = ModelPricing.codex
        let billableInput = max(0, totals.input - totals.cacheRead)
        let output = totals.output + totals.reasoning
        let cost = TokenCostMath.calculateCost(
            input: billableInput,
            output: output,
            cacheCreation: 0,
            cacheRead: totals.cacheRead,
            pricing: pricing
        )

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
                pricingForName: { ModelPricing.codex(for: $0) }
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
                pricingForName: { ModelPricing.codex(for: $0) }
            )
        ), TokenUsageAggregator.makeDailyUsage(
            from: context.dailyTotals,
            provider: .codexCli,
            pricing: pricing,
            modelsByDay: context.dailyModelTotals,
            projectsByDay: context.dailyProjectTotals,
            projectModelsByDay: context.dailyProjectModelTotals,
            pricingForName: { ModelPricing.codex(for: $0) }
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

    /// The byte-level equivalent of the old `line.contains("\"token_count\"")`
    /// prefilter. Rollout files are mostly non-usage events, so skipping
    /// `JSONSerialization` on them is what keeps the scan cheap.
    nonisolated private static let tokenCountMarker = Data("\"token_count\"".utf8)

    /// Same prefilter for the two events that carry the attribution a
    /// `token_count` line lacks. Cheap enough to run on every non-usage line.
    nonisolated private static let turnContextMarker = Data("\"turn_context\"".utf8)
    nonisolated private static let sessionMetaMarker = Data("\"session_meta\"".utf8)

    /// Internal (not private) so the rollout parsing — the Codex counterpart to
    /// `parseSessionFile`, and where CLI-vs-app cost divergence hides — can be
    /// fixture-tested against a temp directory.
    ///
    /// A `token_count` event names neither the model nor the front end, so the
    /// scan streams each file in order and carries the last `turn_context`
    /// model and the opening `session_meta` originator forward. Attribution is
    /// per file: state resets on every rollout.
    nonisolated static func scanRollouts(
        directory: URL,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        guard CostScanFileSystem.isLocalDirectory(directory) else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // The per-file mtime prefilter is gone on purpose: the lifetime window
        // needs every file, and the period window is still bounded by the
        // per-event timestamp check inside `ScanWindows.update` (an event is
        // never newer than the file holding it).
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            // Reset per file: attribution carried across rollouts would label
            // one session's spend with another's model.
            var rollout = CodexRolloutContext()
            // Codex emits a session's opening `token_count` events *before* its
            // first `turn_context`, so forward-only attribution orphaned them
            // even though the same file names the model seconds later. Park
            // them here instead and back-fill once the file declares a model.
            // Per file, like the rollout context: a sibling rollout's model
            // must never name events this file left unexplained.
            var deferred: [CodexDeferredUsage] = []
            var oversizedLines = 0
            FileLineReader.forEachLine(in: fileURL) { line in
                // Ahead of even the marker scan: rollouts embed pasted files and
                // raw tool output, so the biggest lines here are also the ones
                // guaranteed not to be usage records.
                guard CostScanFileSystem.isScannableLine(line) else {
                    oversizedLines += 1
                    return
                }
                guard line.contains(Self.tokenCountMarker) else {
                    Self.updateRolloutContext(&rollout, from: line)
                    // Reaches back only as far as the *first* model the file
                    // declares — a later mid-session switch must not relabel
                    // the events that preceded it.
                    if let model = rollout.turnModel ?? rollout.sessionModel {
                        Self.flushDeferred(&deferred, modelName: model, windows: &windows)
                    }
                    return
                }
                Self.addTokenCountLine(
                    line,
                    fileURL: fileURL,
                    rollout: rollout,
                    deferred: &deferred,
                    windows: &windows
                )
            }
            // Whatever the file never explained is genuinely unattributed.
            Self.flushDeferred(&deferred, modelName: nil, windows: &windows)
            // One line per file, not per skipped line: rollouts hold hundreds of
            // oversized records and the log must stay cheaper than the scan.
            if oversizedLines > 0 {
                AppLog.cost.debug(
                    "Skipped \(oversizedLines, privacy: .public) oversized line(s) in \(fileURL.lastPathComponent)"
                )
            }
        }
    }

    /// Single-window entry point kept for callers that only care about one
    /// period. Scans into `context` as the period window and discards lifetime.
    nonisolated static func scanRollouts(
        directory: URL,
        since cutoffDate: Date,
        context: inout CodexScanContext
    ) {
        var windows = ScanWindows(
            period: context,
            lifetime: CodexScanContext(earliestDate: Date(), latestDate: .distantPast),
            cutoff: cutoffDate
        )
        Self.scanRollouts(directory: directory, windows: &windows)
        context = windows.period
    }

    /// Picks up the model/originator carried by the non-usage rollout events.
    nonisolated private static func updateRolloutContext(
        _ rollout: inout CodexRolloutContext,
        from line: Data
    ) {
        if line.contains(Self.turnContextMarker) {
            guard let payload = Self.eventPayload(in: line, type: "turn_context") else { return }
            rollout.turnModel = (payload["model"] as? String) ?? rollout.turnModel
        } else if line.contains(Self.sessionMetaMarker) {
            guard let payload = Self.eventPayload(in: line, type: "session_meta") else { return }
            // `model` is null on every rollout observed so far, but read it
            // anyway so pre-turn events get named the day Codex populates it.
            rollout.sessionModel = (payload["model"] as? String) ?? rollout.sessionModel
            rollout.originator = (payload["originator"] as? String) ?? rollout.originator
            rollout.cwd = (payload["cwd"] as? String) ?? rollout.cwd
        }
    }

    /// Replays the events parked before the file named a model. Each keeps its
    /// own timestamp, so `ScanWindows.update` still places it on its own day.
    nonisolated private static func flushDeferred(
        _ deferred: inout [CodexDeferredUsage],
        modelName: String?,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        guard !deferred.isEmpty else { return }

        for pending in deferred {
            Self.addUsage(
                pending.usage,
                timestamp: pending.timestamp,
                sessionID: pending.sessionID,
                attribution: CodexUsageAttribution(
                    modelName: modelName,
                    originName: pending.originName,
                    projectID: pending.projectID
                ),
                windows: &windows
            )
        }
        deferred.removeAll()
    }

    nonisolated private static func addTokenCountLine(
        _ line: Data,
        fileURL: URL,
        rollout: CodexRolloutContext,
        deferred: inout [CodexDeferredUsage],
        windows: inout ScanWindows<CodexScanContext>
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

        Self.addUsage(
            usage,
            timestamp: timestamp,
            sessionID: sessionID,
            attribution: CodexUsageAttribution(
                modelName: modelName,
                originName: originName,
                projectID: projectID
            ),
            windows: &windows
        )
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

    nonisolated private static func scanSQLiteLogs(
        database: URL,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        var db: OpaquePointer?
        // SQLite hands back a handle even for most open failures, so the close
        // has to be armed before the status check or the failure path leaks it.
        let openResult = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openResult == SQLITE_OK else { return }

        let sql = """
            SELECT feedback_log_body
            FROM logs
            WHERE feedback_log_body LIKE '%input_token_count=%'
              AND feedback_log_body LIKE '%event.timestamp=%'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bodyPointer = sqlite3_column_text(statement, 0) else { continue }
            let body = String(cString: bodyPointer)
            // No cutoff skip: the window split now happens per event, and the
            // lifetime window needs the rows this used to drop.
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
            Self.addUsage(
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
                ),
                windows: &windows
            )
        }
    }

    /// Stays at five named parameters — SwiftLint's `function_parameter_count`
    /// warns at seven and CI lints with `--strict` — because the cutoff travels
    /// inside `ScanWindows` rather than as its own argument, and `modelName`/
    /// `originName`/`projectID` are bundled into one `CodexUsageAttribution`
    /// value instead of three separate parameters.
    nonisolated private static func addUsage(
        _ usage: [String: Any],
        timestamp: Date,
        sessionID: String,
        attribution: CodexUsageAttribution,
        windows: inout ScanWindows<CodexScanContext>
    ) {
        let input = CostScanValues.int(usage["input_tokens"])
        let cached = CostScanValues.int(usage["cached_input_tokens"])
        let output = CostScanValues.int(usage["output_tokens"])
        let reasoning = CostScanValues.int(usage["reasoning_output_tokens"])
        guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { return }

        // Use whole-millisecond precision for the dedup key so equivalent events
        // produce a stable, collision-resistant string (raw Double formatting can
        // vary and risks both false matches and false misses).
        let timestampMillis = Int((timestamp.timeIntervalSince1970 * 1000).rounded())
        let key = "\(timestampMillis)-\(sessionID)-\(input)-\(cached)-\(output)-\(reasoning)"
        let day = Calendar.current.startOfDay(for: timestamp)
        let modelKey = CostScanValues.displayModelName(attribution.modelName)
        let originKey = CostScanValues.displayOriginName(attribution.originName)
        let projectKey = attribution.projectID

        // Each window keeps its own `eventKeys`, so an event that lands in both
        // is deduplicated independently in each — exactly what the two separate
        // scans did.
        windows.update(at: timestamp) { context in
            guard context.eventKeys.insert(key).inserted else { return }

            context.sessionIDs.insert(sessionID)
            context.totals.add(
                input: input,
                output: output,
                cacheCreation: 0,
                cacheRead: cached,
                reasoning: reasoning
            )
            context.dailyTotals[day, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.dailyModelTotals[day, default: [:]][modelKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.dailyProjectTotals[day, default: [:]][projectKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            var dailyProjectModels = context.dailyProjectModelTotals[day] ?? [:]
            dailyProjectModels[projectKey, default: [:]][
                modelKey,
                default: TokenAccumulator()
            ].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.dailyProjectModelTotals[day] = dailyProjectModels
            context.modelTotals[modelKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.originTotals[originKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.projectTotals[projectKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
            context.projectModelTotals[projectKey, default: [:]][modelKey, default: TokenAccumulator()].add(
                input: input,
                output: output + reasoning,
                cacheCreation: 0,
                cacheRead: cached
            )
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
nonisolated struct CodexRolloutContext: Sendable {
    var turnModel: String?
    var sessionModel: String?
    var originator: String?
    /// Real, unencoded working directory from `session_meta.payload.cwd`
    /// (issue #270) — the non-prompt-content field project attribution is
    /// derived from. `nil` until (or unless) a `session_meta` event supplies it.
    var cwd: String?
}

/// Bundles the three "who/what/where" labels a single usage event needs so
/// `addUsage` can stay under SwiftLint's `function_parameter_count` limit
/// (issue #270 added `projectID` as the third label alongside the pre-existing
/// model/origin pair).
/// A `token_count` event parked because its rollout has not named a model yet.
///
/// Deliberately not `Sendable`: it carries the raw `[String: Any]` usage
/// payload. It never outlives the single-threaded scan of the file that made
/// it, so it does not need to be.
nonisolated struct CodexDeferredUsage {
    let usage: [String: Any]
    let timestamp: Date
    let sessionID: String
    let originName: String
    let projectID: String
}

nonisolated struct CodexUsageAttribution: Sendable {
    let modelName: String?
    let originName: String?
    let projectID: String
}
