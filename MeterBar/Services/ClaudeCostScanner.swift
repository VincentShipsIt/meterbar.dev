import Foundation
import MeterBarShared

/// Reads Claude Code transcripts off disk and turns them into cost totals.
/// Split out of `CostTracker` (audit C1d) so the transcript parsing, project
/// discovery, and per-event tally are testable without publishing a summary.
enum ClaudeCostScanner {
    nonisolated static func scanSessions(
        since cutoffDate: Date,
        claudeAccounts: [ClaudeCodeAccount],
        cache: CostScanCache? = nil
    ) -> ScanWindows<ClaudeSessionTotals> {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: cutoffDate
        )
        let projectRoots = Self.projectRoots(accounts: claudeAccounts)
        guard !projectRoots.isEmpty else { return windows }

        for root in projectRoots {
            let scanned = Self.scanProjectRoot(root, since: cutoffDate, cache: cache)
            windows.period.merge(scanned.period)
            windows.lifetime.merge(scanned.lifetime)
        }

        return windows
    }

    /// Walks one `projects` root. Split out of `scanSessions` so a single root
    /// can be driven from a fixture directory, and so the cache has one seam to
    /// hook rather than one per account.
    nonisolated static func scanProjectRoot(
        _ root: URL,
        since cutoffDate: Date,
        cache: CostScanCache? = nil
    ) -> ScanWindows<ClaudeSessionTotals> {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: cutoffDate
        )
        guard CostScanFileSystem.isLocalDirectory(root) else { return windows }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return windows
        }

        // Cached day buckets can only answer a cutoff that lands on a day
        // boundary — which is what `CostWindow.start(days:)` always produces.
        // Anything else (a hand-rolled cutoff in a test, or a future
        // hour-granular window) falls back to a full parse rather than
        // splitting a bucket it cannot split.
        let reusable = Calendar.current.startOfDay(for: cutoffDate) == cutoffDate

        // No mtime prefilter: the lifetime window needs every file, and the
        // period window is already bounded by the per-event timestamp check
        // (an event is never newer than the file that holds it). The cache below
        // is the answer to the re-parse cost, not a prefilter — an unchanged
        // archive still contributes its full lifetime totals, just without
        // being read again.
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Computed once per file, not per event: project identity is a
            // property of where the transcript lives, unlike `usageOrigin`
            // which can vary line-to-line within the same file.
            let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: url, root: root)
            let file = Self.sessionWindows(
                at: url,
                since: cutoffDate,
                projectID: projectID,
                cache: reusable ? cache : nil,
                recordingInto: cache
            )
            windows.period.merge(file.period)
            windows.lifetime.merge(file.lifetime)
        }

        return windows
    }

    /// One transcript, served from `cache` when its stamp still matches and its
    /// digest reconstructs cleanly, parsed from disk otherwise.
    nonisolated private static func sessionWindows(
        at url: URL,
        since cutoffDate: Date,
        projectID: String,
        cache: CostScanCache?,
        recordingInto recorder: CostScanCache?
    ) -> ScanWindows<ClaudeSessionTotals> {
        let stamp = CostScanFileStamp.read(at: url)

        if let cache, let stamp,
           let entry = cache.claudeEntry(forPath: url.path, stamp: stamp),
           entry.digest.projectID == projectID,
           let period = entry.digest.totals(since: cutoffDate),
           let lifetime = entry.digest.totals(since: .distantPast) {
            cache.noteHit(carrying: entry)
            return ScanWindows(period: period, lifetime: lifetime, cutoff: cutoffDate)
        }

        recorder?.noteMiss()
        let parsed = Self.parseTranscript(at: url, since: cutoffDate, projectID: projectID)
        if let recorder, let stamp, let digest = parsed.digest {
            recorder.store(ClaudeCacheEntry(path: url.path, stamp: stamp, digest: digest))
        }
        return parsed.windows
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

    nonisolated private static func projectRoots(accounts: [ClaudeCodeAccount]) -> [URL] {
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
        Self.parseTranscript(at: url, since: cutoffDate, projectID: projectID).windows
    }

    /// The streaming parse, plus the day-bucketed digest the cache stores.
    ///
    /// `digest` is `nil` when the transcript cannot be summarized without risking
    /// a wrong number — see `makeDigest` for the two cases. A `nil` digest costs
    /// a re-parse next time; a wrong one would cost the dashboard's credibility.
    nonisolated static func parseTranscript(
        at url: URL,
        since cutoffDate: Date,
        projectID: String = CostProjectAttribution.unknownProjectID
    ) -> (windows: ScanWindows<ClaudeSessionTotals>, digest: ClaudeTranscriptDigest?) {
        var periodKeyed: [String: ClaudeUsageEvent] = [:]
        var periodUnkeyed: [ClaudeUsageEvent] = []
        var lifetimeKeyed: [String: ClaudeUsageEvent] = [:]
        var lifetimeUnkeyed: [ClaudeUsageEvent] = []
        // A key that resolves to two *different* events makes the file
        // uncacheable: last-wins is applied per window, so which copy survives
        // depends on where the cutoff falls — something a cutoff-independent
        // digest cannot represent.
        var ambiguous = false
        var negativeTokens = false

        FileLineReader.forEachLine(in: url) { lineData in
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestampStr = json["timestamp"] as? String,
                  let timestamp = FlexibleISO8601.date(from: timestampStr),
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                return
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
            guard event.hasUsage else { return }
            if event.hasNegativeTokens { negativeTokens = true }

            let inPeriod = timestamp >= cutoffDate
            if let key = event.deduplicationKey {
                if let existing = lifetimeKeyed[key], existing != event { ambiguous = true }
                lifetimeKeyed[key] = event
                if inPeriod { periodKeyed[key] = event }
            } else {
                lifetimeUnkeyed.append(event)
                if inPeriod { periodUnkeyed.append(event) }
            }
        }

        let lifetimeEvents = Self.orderedEvents(keyed: lifetimeKeyed, unkeyed: lifetimeUnkeyed)
        let windows = ScanWindows(
            period: Self.tally(events: Self.orderedEvents(keyed: periodKeyed, unkeyed: periodUnkeyed),
                               projectID: projectID),
            lifetime: Self.tally(events: lifetimeEvents, projectID: projectID),
            cutoff: cutoffDate
        )
        let digest = (ambiguous || negativeTokens)
            ? nil
            : Self.makeDigest(from: lifetimeEvents, projectID: projectID)
        return (windows, digest)
    }

    /// Keyed events first, in key order, then the unkeyed ones in file order —
    /// the traversal order the totals have always been accumulated in.
    nonisolated private static func orderedEvents(
        keyed: [String: ClaudeUsageEvent],
        unkeyed: [ClaudeUsageEvent]
    ) -> [ClaudeUsageEvent] {
        keyed.keys.sorted().compactMap { keyed[$0] } + unkeyed
    }

    /// Collapses one transcript's deduplicated events into per-day,
    /// per-(model, origin) token sums.
    ///
    /// Costs are deliberately *not* stored: `calculateClaudeCost` is linear in
    /// each non-negative token count, so recomputing from the sums reproduces
    /// the per-event total, and a pricing-table change then lands on cached
    /// files as well as fresh ones.
    nonisolated private static func makeDigest(
        from events: [ClaudeUsageEvent],
        projectID: String
    ) -> ClaudeTranscriptDigest {
        var models = CostScanStringTable()
        var origins = CostScanStringTable()
        // Keyed by day, then by (model index, origin index), holding the running
        // token sums in `bucketStride` order.
        var byDay: [Date: [BucketKey: [Int]]] = [:]
        var extremes: [Date: (earliest: Date, latest: Date)] = [:]
        var dayOrder: [Date] = []
        var bucketOrder: [Date: [BucketKey]] = [:]

        for event in events {
            let day = Calendar.current.startOfDay(for: event.timestamp)
            let key = BucketKey(
                model: event.model.map { models.index(of: $0) } ?? ClaudeTranscriptDigest.nilModelIndex,
                origin: origins.index(of: event.origin)
            )

            if byDay[day] == nil {
                byDay[day] = [:]
                bucketOrder[day] = []
                dayOrder.append(day)
                extremes[day] = (event.timestamp, event.timestamp)
            } else if let current = extremes[day] {
                extremes[day] = (
                    min(current.earliest, event.timestamp),
                    max(current.latest, event.timestamp)
                )
            }

            if byDay[day]?[key] == nil {
                byDay[day]?[key] = [key.model, key.origin, 0, 0, 0, 0, 0, 0]
                bucketOrder[day]?.append(key)
            }
            byDay[day]?[key]?[2] += event.input
            byDay[day]?[key]?[3] += event.output
            byDay[day]?[key]?[4] += event.cacheCreation
            byDay[day]?[key]?[5] += event.cacheCreationOneHour
            byDay[day]?[key]?[6] += event.cacheRead
            byDay[day]?[key]?[7] += 1
        }

        let days = dayOrder.compactMap { day -> ClaudeTranscriptDigest.Day? in
            guard let buckets = byDay[day], let order = bucketOrder[day], let span = extremes[day] else {
                return nil
            }
            return ClaudeTranscriptDigest.Day(
                day: day.timeIntervalSinceReferenceDate,
                earliest: span.earliest.timeIntervalSinceReferenceDate,
                latest: span.latest.timeIntervalSinceReferenceDate,
                buckets: order.flatMap { buckets[$0] ?? [] }
            )
        }

        return ClaudeTranscriptDigest(
            projectID: projectID,
            models: models.values,
            origins: origins.values,
            days: days
        )
    }

    nonisolated private struct BucketKey: Hashable {
        let model: Int
        let origin: Int
    }

    nonisolated private static func tally(
        events: [ClaudeUsageEvent],
        projectID: String
    ) -> ClaudeSessionTotals {
        var totals = ClaudeSessionTotals()

        for event in events {
            let pricing = Self.pricing(for: event.model)
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

    nonisolated static func pricing(for model: String?) -> TokenPricing {
        ModelPricing.claude(for: model)
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

nonisolated private struct ClaudeUsageEvent: Sendable, Equatable {
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

    /// `CostScanValues.int` passes negatives through, and the cost math clamps
    /// each field to zero *per event*. Summing first would let a negative field
    /// cancel a positive one from another event and change the total, so a
    /// transcript containing one is never summarized.
    var hasNegativeTokens: Bool {
        input < 0 || output < 0 || cacheCreation < 0 || cacheCreationOneHour < 0 || cacheRead < 0
    }

    var deduplicationKey: String? {
        guard let messageID, let requestID else { return nil }
        return "\(messageID):\(requestID)"
    }
}
