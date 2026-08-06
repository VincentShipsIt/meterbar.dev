import Foundation
import MeterBarShared
import os

/// Reads Claude Code transcripts off disk and turns them into cost totals.
/// Split out of `CostTracker` (audit C1d) so the transcript parsing, project
/// discovery, and per-event tally are testable without publishing a summary.
enum ClaudeCostScanner {
    nonisolated static func scanSessions(
        since cutoffDate: Date,
        claudeAccounts: [ClaudeCodeAccount],
        width: Int = CostScanParallel.defaultWidth
    ) -> ScanWindows<ClaudeSessionTotals> {
        scanSessions(
            since: cutoffDate,
            projectRoots: Self.projectRoots(accounts: claudeAccounts),
            width: width
        )
    }

    /// Roots-explicit seam. The account-based entry point always includes the
    /// real `~/.claude*/projects` directories, so tests that want to scan a
    /// fixture tree — and only that tree — go through here.
    ///
    /// Deduplication is per file: `parseSessionWindows` keeps its own
    /// `messageID:requestID` map and throws it away at the end of each
    /// transcript, so a file's totals depend on nothing outside that file and
    /// merging them is a plain sum. That is what makes the parse safe to fan
    /// out. The merge itself stays serial and in sorted-path order because
    /// summing `Double` costs is not associative.
    nonisolated static func scanSessions(
        since cutoffDate: Date,
        projectRoots: [URL],
        width: Int = CostScanParallel.defaultWidth
    ) -> ScanWindows<ClaudeSessionTotals> {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: cutoffDate
        )
        guard !projectRoots.isEmpty else { return windows }

        for root in projectRoots {
            // No mtime prefilter: the lifetime window needs every file, and the
            // period window is already bounded by the per-event timestamp check
            // (an event is never newer than the file that holds it).
            let files = CostScanFileSystem.transcriptFiles(
                in: root,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            CostScanParallel.parseInOrder(
                files,
                width: width,
                parse: { url in
                    // Computed once per file, not per event: project identity is
                    // a property of where the transcript lives, unlike
                    // `usageOrigin` which can vary line-to-line within the same
                    // file.
                    let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: url, root: root)
                    return Self.parseSessionWindows(at: url, since: cutoffDate, projectID: projectID)
                },
                fold: { file in
                    windows.period.merge(file.period)
                    windows.lifetime.merge(file.lifetime)
                }
            )
        }

        return windows
    }

    /// `windowStart` is the floor the old code seeded `latestDate` with — the
    /// cutoff for the period window, `.distantPast` for lifetime.
    nonisolated static func makeCost(
        from totals: ClaudeSessionTotals,
        windowStart: Date
    ) -> (TokenCost, [DailyTokenUsage])? {
        guard totals.hasUsage else { return nil }

        let pricing = ModelPricing.claude(for: nil)
        let fallbackCost = TokenCostMath.calculateCost(
            input: totals.input,
            output: totals.output,
            cacheCreation: totals.cacheCreation,
            cacheRead: totals.cacheRead,
            pricing: pricing
        )
        let cost = totals.estimatedCost > 0 ? totals.estimatedCost : fallbackCost
        let now = Date()

        return (TokenCost(
            provider: .claudeCode,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheCreationTokens: totals.cacheCreation,
            cacheReadTokens: totals.cacheRead,
            estimatedCostUSD: cost,
            sessionCount: totals.sessions,
            periodStart: min(now, totals.earliest ?? now),
            periodEnd: max(windowStart, totals.latest ?? windowStart),
            modelBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: totals.models,
                provider: .claudeCode,
                pricing: pricing
            ),
            originBreakdowns: TokenUsageAggregator.makeBreakdowns(
                from: totals.origins,
                provider: .claudeCode,
                pricing: pricing
            ),
            projectBreakdowns: TokenUsageAggregator.makeProjectBreakdowns(
                from: totals.projects,
                modelsByProject: totals.projectModels,
                provider: .claudeCode,
                pricing: pricing
            )
        ), TokenUsageAggregator.makeDailyUsage(
            from: totals.daily,
            provider: .claudeCode,
            pricing: pricing,
            modelsByDay: totals.dailyModels,
            projectsByDay: totals.dailyProjects,
            projectModelsByDay: totals.dailyProjectModels
        ))
    }

    /// Internal (not private) so the budgeted scan can enumerate the same roots
    /// the whole-corpus scan walks.
    nonisolated static func projectRoots(accounts: [ClaudeCodeAccount]) -> [URL] {
        let fileManager = FileManager.default
        // realHomeDirectory, not homeDirectoryForCurrentUser: in sandboxed
        // builds the latter is the app container, and the scan would silently
        // find zero logs while quota fetching kept working.
        let home = URL(fileURLWithPath: ServiceSupport.realHomeDirectory(), isDirectory: true)
        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            roots.append(contentsOf: env.split(separator: ",").map { part in
                Self.projectsURL(forConfigPath: String(part))
            })
        }

        roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))

        for account in accounts {
            guard let configDirectory = account.configDirectory else { continue }
            roots.append(Self.projectsURL(forConfigPath: configDirectory))
        }

        if let homeEntries = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for entry in homeEntries where entry.lastPathComponent.hasPrefix(".claude-") {
                roots.append(entry.appendingPathComponent("projects", isDirectory: true))
            }
        }

        var seen = Set<String>()
        return roots.compactMap { url in
            let standardized = url.standardizedFileURL
            guard CostScanFileSystem.isLocalDirectory(standardized),
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    /// Internal (not private) so the config-path normalization can be unit-tested.
    nonisolated static func projectsURL(forConfigPath rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: (trimmed as NSString).standardizingPath)
        if url.lastPathComponent == "projects" {
            return url
        }
        return url.appendingPathComponent("projects", isDirectory: true)
    }

    /// Convenience wrapper for the reporting window alone. `projectID` defaults
    /// to the explicit "unknown" bucket so every pre-#270 call site (including
    /// the bulk of this file's own test suite) keeps working unchanged instead
    /// of being forced to name a project it doesn't care about.
    nonisolated static func parseSessionFile(
        at url: URL,
        since cutoffDate: Date,
        projectID: String = CostProjectAttribution.unknownProjectID
    ) -> ClaudeSessionTotals {
        Self.parseSessionWindows(at: url, since: cutoffDate, projectID: projectID).period
    }

    /// Parses one transcript into both windows in a single streaming pass.
    ///
    /// Dedup state is deliberately kept per window. Two events can share a
    /// `messageID:requestID` key while straddling the cutoff; one shared map
    /// would let the older copy overwrite the in-window one and change the
    /// period total.
    ///
    /// `projectID` is a single value for the whole file (issue #270): unlike
    /// per-event fields such as model or origin, project identity comes from
    /// where the transcript lives on disk, not from anything inside it.
    nonisolated static func parseSessionWindows(
        at url: URL,
        since cutoffDate: Date,
        projectID: String = CostProjectAttribution.unknownProjectID
    ) -> ScanWindows<ClaudeSessionTotals> {
        var periodKeyed: [String: ClaudeUsageEvent] = [:]
        var periodUnkeyed: [ClaudeUsageEvent] = []
        var lifetimeKeyed: [String: ClaudeUsageEvent] = [:]
        var lifetimeUnkeyed: [ClaudeUsageEvent] = []

        // A line the reader had to truncate is parsed like any other: the usage
        // block sits near the front of a transcript record, so the retained
        // prefix often still decodes. Only a prefix that fails to parse is
        // skipped — never the line for being long.
        FileLineReader.forEachLine(in: url) { line in
            guard let event = Self.usageEvent(from: line.bytes, url: url) else { return }

            let inPeriod = event.timestamp >= cutoffDate
            if let key = event.deduplicationKey {
                lifetimeKeyed[key] = event
                if inPeriod { periodKeyed[key] = event }
            } else {
                lifetimeUnkeyed.append(event)
                if inPeriod { periodUnkeyed.append(event) }
            }
        }

        return ScanWindows(
            period: Self.tally(keyed: periodKeyed, unkeyed: periodUnkeyed, projectID: projectID),
            lifetime: Self.tally(keyed: lifetimeKeyed, unkeyed: lifetimeUnkeyed, projectID: projectID),
            cutoff: cutoffDate
        )
    }

    /// Decodes one transcript line into a usage event, or `nil` when the line is
    /// not one (blank, malformed, or a non-usage record).
    nonisolated private static func usageEvent(from lineData: Data, url: URL) -> ClaudeUsageEvent? {
        guard !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let timestampStr = json["timestamp"] as? String,
              let timestamp = FlexibleISO8601.date(from: timestampStr),
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        let event = ClaudeUsageEvent(
            timestamp: timestamp,
            model: message["model"] as? String,
            messageID: message["id"] as? String,
            requestID: json["requestId"] as? String,
            input: CostScanValues.int(usage["input_tokens"]),
            output: CostScanValues.int(usage["output_tokens"]),
            cacheCreation: CostScanValues.int(usage["cache_creation_input_tokens"]),
            cacheCreationOneHour: Self.oneHourCacheCreationTokens(in: usage),
            cacheRead: CostScanValues.int(usage["cache_read_input_tokens"]),
            origin: Self.usageOrigin(json: json, message: message, url: url)
        )
        return event.hasUsage ? event : nil
    }

    // MARK: - Budgeted, resumable scan

    /// Walks `roots` newest transcript first, reading only bytes appended since
    /// the last refresh and stopping when `session`'s budget runs out.
    ///
    /// Every file's tally lives on its own cache entry, so a refresh that only
    /// gets through the newest handful still returns the *whole* corpus total —
    /// freshly-read files plus every previously-cached one. The number on screen
    /// improves monotonically as the slices land instead of appearing all at
    /// once after a 70-second freeze.
    nonisolated static func scanRoots(
        _ roots: [URL],
        session: CostScanSession
    ) -> ScanWindows<ClaudeSessionTotals> {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: session.cutoff
        )
        var live: Set<String> = []

        for root in roots {
            guard CostScanFileSystem.isLocalDirectory(root) else { continue }

            for file in CostScanCorpus.transcripts(in: root) {
                // `projectRoots` can name the same directory twice (an account's
                // configured path is often just `~/.claude`), and the cache is
                // keyed by standardized path — counting a file once per root
                // would double its spend.
                guard live.insert(file.cacheKey).inserted else { continue }

                let projectID = CostProjectAttribution.claudeProjectID(
                    forTranscriptURL: file.url,
                    root: root
                )
                guard let file = Self.totals(for: file, projectID: projectID, session: session) else {
                    continue
                }
                windows.period.merge(file.period)
                windows.lifetime.merge(file.lifetime)
            }
        }

        // Enumeration always runs to completion even when the read budget is
        // spent, so `live` is every transcript that exists — safe to prune
        // against on a partial refresh. Without it, deleted transcripts would
        // keep contributing their totals forever.
        session.retainClaude(keys: live)
        return windows
    }

    /// One transcript's contribution: cached, resumed, or skipped.
    ///
    /// - Returns: `nil` when the file has never been read and there was no
    ///   budget left to start it, so it contributes nothing this refresh.
    nonisolated private static func totals(
        for file: CostScanFile,
        projectID: String,
        session: CostScanSession
    ) -> ScanWindows<ClaudeSessionTotals>? {
        let record = Self.resumableRecord(for: file, session: session)

        // Nothing appended since the last pass. This is the steady state once
        // the corpus is warm, and it is why a refresh costs almost no I/O.
        if let record, record.isComplete, record.stamp.matches(file.stamp) {
            return Self.windows(record.payload, cutoff: session.cutoff)
        }

        let allowance = session.budget.allowance
        guard allowance > 0 else {
            session.noteDeferred()
            return record.map { Self.windows($0.payload, cutoff: session.cutoff) }
        }

        var payload = record?.payload ?? ClaudeFileTotals()
        var request = FileLineReadRequest()
        request.startOffset = record?.offset ?? 0
        request.maxBytes = allowance

        var periodKeyed: [String: ClaudeUsageEvent] = [:]
        var periodUnkeyed: [ClaudeUsageEvent] = []
        var lifetimeKeyed: [String: ClaudeUsageEvent] = [:]
        var lifetimeUnkeyed: [ClaudeUsageEvent] = []

        let read = FileLineReader.readLines(in: file.url, request: request) { line, _ in
            guard let event = Self.usageEvent(from: line.bytes, url: file.url) else { return }

            if let key = event.deduplicationKey {
                // First-wins across a resume boundary: an event with this key is
                // already folded into `payload`, and its bytes are behind the
                // committed offset. Within a single pass the last copy still
                // wins, exactly as a cold scan does.
                if !payload.lifetimeKeys.contains(key) {
                    lifetimeKeyed[key] = event
                }
                if event.timestamp >= session.cutoff, !payload.periodKeys.contains(key) {
                    periodKeyed[key] = event
                }
            } else {
                lifetimeUnkeyed.append(event)
                if event.timestamp >= session.cutoff { periodUnkeyed.append(event) }
            }
        }

        guard let read else {
            // Unreadable (permissions, deleted mid-scan). Keep whatever the
            // cache already had rather than dropping the file's history.
            return record.map { Self.windows($0.payload, cutoff: session.cutoff) }
        }
        session.budget.consume(read.bytesRead)

        payload.period.merge(Self.tally(keyed: periodKeyed, unkeyed: periodUnkeyed, projectID: projectID))
        payload.lifetime.merge(Self.tally(keyed: lifetimeKeyed, unkeyed: lifetimeUnkeyed, projectID: projectID))
        // `merge` sums `sessions`, but one transcript is one session however
        // many slices it took to read.
        payload.period.sessions = payload.period.hasUsage ? 1 : 0
        payload.lifetime.sessions = payload.lifetime.hasUsage ? 1 : 0

        if read.reachedEndOfFile {
            // Dedup keys only matter while a read can resume mid-file. Keeping
            // ~10k files' worth of them on disk forever would cost more to load
            // than the scan they save.
            payload.periodKeys = []
            payload.lifetimeKeys = []
        } else {
            payload.periodKeys.formUnion(periodKeyed.keys)
            payload.lifetimeKeys.formUnion(lifetimeKeyed.keys)
            session.noteDeferred()
        }

        session.setClaudeRecord(
            CostScanFileRecord(
                offset: read.committedOffset,
                stamp: file.stamp,
                cutoff: session.cutoff,
                isComplete: read.reachedEndOfFile,
                payload: payload
            ),
            for: file.cacheKey
        )
        return Self.windows(payload, cutoff: session.cutoff)
    }

    /// The cached entry to resume from, rebased onto this refresh's cutoff.
    ///
    /// - Returns: `nil` when the file has to be re-read from byte zero.
    nonisolated private static func resumableRecord(
        for file: CostScanFile,
        session: CostScanSession
    ) -> CostScanFileRecord<ClaudeFileTotals>? {
        guard var record = session.claudeRecord(for: file.cacheKey) else { return nil }
        guard record.offset <= UInt64(file.size) else { return nil }
        if record.isComplete, record.stamp.size == file.size {
            guard record.stamp.matches(file.stamp) else { return nil }
        } else {
            guard record.stamp.isSameFile(as: file.stamp),
                  file.size >= record.stamp.size else { return nil }
        }
        guard record.cutoff != session.cutoff else { return record }

        // The period window slides every day; lifetime totals never expire. So
        // the only question is whether the cached period tally can be rebased
        // without re-reading the file.
        let lifetime = record.payload.lifetime
        if (lifetime.latest ?? .distantPast) < session.cutoff {
            // Every event predates the new window.
            record.payload.period = ClaudeSessionTotals()
            record.payload.periodKeys = []
        } else if (lifetime.earliest ?? .distantFuture) >= session.cutoff {
            // Every event falls inside it.
            record.payload.period = lifetime
            record.payload.periodKeys = record.payload.lifetimeKeys
        } else {
            // The file straddles the cutoff and only its individual events know
            // where. Re-read it — but only files that actually straddle pay.
            return nil
        }
        record.cutoff = session.cutoff
        return record
    }

    nonisolated private static func windows(
        _ payload: ClaudeFileTotals,
        cutoff: Date
    ) -> ScanWindows<ClaudeSessionTotals> {
        ScanWindows(period: payload.period, lifetime: payload.lifetime, cutoff: cutoff)
    }

    nonisolated private static func tally(
        keyed: [String: ClaudeUsageEvent],
        unkeyed: [ClaudeUsageEvent],
        projectID: String
    ) -> ClaudeSessionTotals {
        var totals = ClaudeSessionTotals()
        let events = keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed

        for event in events {
            // Price at the rate in effect when the event was recorded, not
            // today's (issue #339).
            let resolved = Self.resolvePricing(for: event.model, at: event.timestamp)
            let pricing = resolved.pricing
            totals.pricing.record(resolved)
            let eventCost = TokenCostMath.calculateClaudeCost(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheCreationOneHour: event.cacheCreationOneHour,
                cacheRead: event.cacheRead,
                pricing: pricing
            )
            let day = Calendar.current.startOfDay(for: event.timestamp)

            totals.input += event.input
            totals.output += event.output
            totals.cacheCreation += event.cacheCreation
            totals.cacheRead += event.cacheRead
            totals.estimatedCost += eventCost
            totals.note(event.timestamp)
            totals.daily[day, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            let displayModel = CostScanValues.displayModelName(event.model)
            totals.dailyModels[day, default: [:]][displayModel, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            totals.dailyProjects[day, default: [:]][projectID, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            var dailyProjectModels = totals.dailyProjectModels[day] ?? [:]
            dailyProjectModels[projectID, default: [:]][
                displayModel,
                default: TokenAccumulator()
            ].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            totals.dailyProjectModels[day] = dailyProjectModels
            totals.models[displayModel, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            totals.origins[event.origin, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            totals.projects[projectID, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            totals.projectModels[projectID, default: [:]][displayModel, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
        }

        // One transcript with usage counts as one session, matching the old
        // per-file `sessionCount += 1`.
        totals.sessions = totals.hasUsage ? 1 : 0
        return totals
    }

    /// Internal (not private) so the one-hour cache clamp can be unit-tested.
    nonisolated static func oneHourCacheCreationTokens(in usage: [String: Any]) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
        let total = CostScanValues.int(usage["cache_creation_input_tokens"])
        let oneHour = CostScanValues.int(cacheCreation["ephemeral_1h_input_tokens"])
        return min(total, max(0, oneHour))
    }

    nonisolated static func pricing(for model: String?, at timestamp: Date = Date()) -> TokenPricing {
        ModelPricing.claude(for: model, at: timestamp)
    }

    nonisolated static func resolvePricing(for model: String?, at timestamp: Date) -> ResolvedPricing {
        ModelPricing.resolveClaude(for: model, at: timestamp)
    }

    nonisolated static func normalizeModel(_ raw: String) -> String {
        ModelPricing.normalizeClaudeModel(raw)
    }

    /// Internal (not private) so the origin classifier can be unit-tested.
    nonisolated static func usageOrigin(
        json: [String: Any],
        message: [String: Any],
        url: URL
    ) -> String {
        if url.path.contains("/subagents/") || (json["isSidechain"] as? Bool == true) {
            return "Agents"
        }

        let toolNames = Self.toolUseNames(in: message)
        if toolNames.contains(where: { $0.localizedCaseInsensitiveContains("skill") }) {
            return "Skills"
        }
        if toolNames.contains(where: { name in
            let lowercased = name.lowercased()
            return lowercased.contains("agent") || lowercased.contains("task")
        }) {
            return "Agents"
        }
        if !toolNames.isEmpty {
            return "Tool use"
        }

        return "Main chat"
    }

    nonisolated private static func toolUseNames(in message: [String: Any]) -> [String] {
        guard let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use" else { return nil }
            return item["name"] as? String
        }
    }
}

nonisolated private struct ClaudeUsageEvent: Sendable {
    let timestamp: Date
    let model: String?
    let messageID: String?
    let requestID: String?
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheCreationOneHour: Int
    let cacheRead: Int
    let origin: String

    var hasUsage: Bool {
        input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0
    }

    var deduplicationKey: String? {
        guard let messageID, let requestID else { return nil }
        return "\(messageID):\(requestID)"
    }
}
