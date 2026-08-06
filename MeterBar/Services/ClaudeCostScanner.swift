import Foundation
import MeterBarShared
import os

/// Reads Claude Code transcripts off disk and turns them into cost totals.
/// Split out of `CostTracker` (audit C1d) so the transcript parsing, project
/// discovery, and per-event tally are testable without publishing a summary.
enum ClaudeCostScanner {
    nonisolated static func scanSessions(
        since cutoffDate: Date,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> ScanWindows<ClaudeSessionTotals> {
        var windows = ScanWindows(
            period: ClaudeSessionTotals(),
            lifetime: ClaudeSessionTotals(),
            cutoff: cutoffDate
        )
        let projectRoots = Self.projectRoots(accounts: claudeAccounts)
        guard !projectRoots.isEmpty else { return windows }

        for root in projectRoots {
            guard CostScanFileSystem.isLocalDirectory(root) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            // No mtime prefilter: the lifetime window needs every file, and the
            // period window is already bounded by the per-event timestamp check
            // (an event is never newer than the file that holds it).
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                // Computed once per file, not per event: project identity is a
                // property of where the transcript lives, unlike `usageOrigin`
                // which can vary line-to-line within the same file.
                let projectID = CostProjectAttribution.claudeProjectID(forTranscriptURL: url, root: root)
                let file = Self.parseSessionWindows(at: url, since: cutoffDate, projectID: projectID)
                windows.period.merge(file.period)
                windows.lifetime.merge(file.lifetime)
            }
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
        var periodKeyed: [String: ClaudeUsageEvent] = [:]
        var periodUnkeyed: [ClaudeUsageEvent] = []
        var lifetimeKeyed: [String: ClaudeUsageEvent] = [:]
        var lifetimeUnkeyed: [ClaudeUsageEvent] = []

        // A line the reader had to truncate is parsed like any other: the usage
        // block sits near the front of a transcript record, so the retained
        // prefix often still decodes. Only a prefix that fails to parse is
        // skipped — never the line for being long.
        FileLineReader.forEachLine(in: url) { line in
            let lineData = line.bytes
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

            let inPeriod = timestamp >= cutoffDate
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
