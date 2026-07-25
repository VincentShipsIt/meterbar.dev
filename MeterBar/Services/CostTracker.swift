import Combine
import MeterBarShared
import Foundation
import os
import SQLite3

class CostTracker: ObservableObject {
    static let shared = CostTracker(demoMode: DemoMode.isActive)

    @Published var costSummary: CostSummary?
    @Published var isScanning: Bool = false
    @Published var isRefreshingMissingDays: Bool = false
    @Published var lastScanDate: Date?

    private let providerVisibilityStore = ProviderVisibilityStore.shared

    /// When true, the tracker publishes the synthetic `DemoData.costSummary`
    /// fixture and performs no real log scans or cache writes. Gated at `shared`
    /// on `DemoMode.isActive`.
    private let demoMode: Bool

    /// True while either a manual scan or a background missing-day backfill runs.
    var isRefreshInProgress: Bool {
        isScanning || isRefreshingMissingDays
    }

    // Cached regexes. The scan parses tens of thousands of log lines, so
    // allocating an NSRegularExpression per call was a measurable hot-path
    // cost. Date parsing shares the cached FlexibleISO8601 formatters.
    nonisolated private static let codexLogValueRegexes: [String: NSRegularExpression] = {
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

    init(demoMode: Bool = false) {
        self.demoMode = demoMode
        guard !demoMode else {
            // Publish the synthetic fixture; never read the real cache or scan
            // real CLI logs. Real cost data on disk is left untouched.
            costSummary = DemoData.costSummary()
            lastScanDate = Date()
            return
        }
        loadCachedSummary()
    }

    func scanCosts(days: Int = 30) async {
        guard !demoMode else { return }
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress else { return false }
            isScanning = true
            return true
        }
        guard shouldStart else { return }

        let summary = await makeCostSummary(days: days, priority: .userInitiated)

        await MainActor.run {
            costSummary = summary
            lastScanDate = Date()
            saveCachedSummary()
            isScanning = false
        }
    }

    /// Quietly backfills a legacy cache's missing lifetime snapshot or missing
    /// daily rows when Overview/Costs opens, without the visible "Scanning" UI
    /// a manual scan shows.
    func refreshMissingDaysInBackground(days: Int = 30) async {
        guard !demoMode else { return }
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress,
                  let visibleSummary = costSummary?.filtered(to: providerVisibilityStore.enabledServices),
                  visibleSummary.lifetime == nil
                    || visibleSummary.needsMissingDailyUsageRefresh(days: days, lastScanDate: lastScanDate) else {
                return false
            }
            isRefreshingMissingDays = true
            return true
        }
        guard shouldStart else { return }

        let summary = await makeCostSummary(days: days, priority: .utility)

        await MainActor.run {
            costSummary = summary
            lastScanDate = Date()
            saveCachedSummary()
            isRefreshingMissingDays = false
        }
    }

    private func makeCostSummary(days: Int, priority: TaskPriority) async -> CostSummary {
        let includeClaudeCode = providerVisibilityStore.isEnabled(.claudeCode)
        let includeCodexCli = providerVisibilityStore.isEnabled(.codexCli)
        let claudeAccounts = ClaudeCodeAccountStore.shared.accounts
        return await Task.detached(priority: priority) {
            Self.buildCostSummary(
                days: days,
                includeClaudeCode: includeClaudeCode,
                includeCodexCli: includeCodexCli,
                claudeAccounts: claudeAccounts
            )
        }.value
    }

    nonisolated private static func buildCostSummary(
        days: Int,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> CostSummary {
        let cutoffDate = Self.costWindowStart(days: days)
        let periodScan = Self.scanCostSources(
            since: cutoffDate,
            includeClaudeCode: includeClaudeCode,
            includeCodexCli: includeCodexCli,
            claudeAccounts: claudeAccounts
        )
        let lifetimeScan = Self.scanCostSources(
            since: .distantPast,
            includeClaudeCode: includeClaudeCode,
            includeCodexCli: includeCodexCli,
            claudeAccounts: claudeAccounts
        )

        return CostSummary(
            costs: periodScan.costs,
            totalCostUSD: periodScan.costs.reduce(0) { $0 + $1.estimatedCostUSD },
            totalTokens: periodScan.costs.reduce(0) { $0 + $1.totalTokens },
            periodDays: days,
            dailyUsage: periodScan.dailyUsage.sorted { $0.date < $1.date },
            lifetime: LifetimeCostSummary(costs: lifetimeScan.costs)
        )
    }

    /// Inclusive calendar-day boundary shared by the scan and 30-day charts.
    /// `days: 30` means today plus the previous 29 local calendar days, not a
    /// rolling 720-hour interval that can spill into a 31st date bucket.
    nonisolated static func costWindowStart(
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let normalizedDays = max(1, days)
        let today = calendar.startOfDay(for: now)
        return calendar.date(
            byAdding: .day,
            value: -(normalizedDays - 1),
            to: today
        ) ?? today
    }

    nonisolated private static func scanCostSources(
        since cutoffDate: Date,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> (costs: [TokenCost], dailyUsage: [DailyTokenUsage]) {
        var allCosts: [TokenCost] = []
        var dailyUsage: [DailyTokenUsage] = []

        if includeClaudeCode,
           let (claudeCost, claudeDailyUsage) = Self.scanClaudeCodeSessions(
            since: cutoffDate,
            claudeAccounts: claudeAccounts
           ) {
            allCosts.append(claudeCost)
            dailyUsage.append(contentsOf: claudeDailyUsage)
        }

        if includeCodexCli,
           let (codexCost, codexDailyUsage) = Self.scanCodexSessions(since: cutoffDate) {
            allCosts.append(codexCost)
            dailyUsage.append(contentsOf: codexDailyUsage)
        }

        return (allCosts, dailyUsage)
    }

    private func loadCachedSummary() {
        guard let cache = CostSummaryStore.load() else { return }
        costSummary = cache.summary
        lastScanDate = cache.lastScanDate
    }

    private func saveCachedSummary() {
        guard !demoMode else { return }
        guard let costSummary, let lastScanDate else { return }

        do {
            try CostSummaryStore.save(CostSummaryCache(summary: costSummary, lastScanDate: lastScanDate))
        } catch {
            AppLog.cost.error("Failed to save cost summary cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func scanClaudeCodeSessions(
        since cutoffDate: Date,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> (TokenCost, [DailyTokenUsage])? {
        let projectRoots = Self.claudeProjectRoots(accounts: claudeAccounts)
        guard !projectRoots.isEmpty else { return nil }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var totalEstimatedCost = 0.0
        var sessionCount = 0
        var earliestDate = Date()
        var latestDate = cutoffDate
        var dailyTotals: [Date: TokenAccumulator] = [:]
        var modelTotals: [String: TokenAccumulator] = [:]
        var originTotals: [String: TokenAccumulator] = [:]

        for root in projectRoots {
            guard Self.isLocalDirectory(root) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modificationDate = values.contentModificationDate,
                      modificationDate >= cutoffDate else {
                    continue
                }

                let (input, output, cacheCreate, cacheReadTokens, estimatedCost, dates, daily, models, origins) =
                    Self.parseSessionFile(at: url, since: cutoffDate)

                if input > 0 || output > 0 || cacheCreate > 0 || cacheReadTokens > 0 {
                    totalInput += input
                    totalOutput += output
                    totalCacheCreation += cacheCreate
                    totalCacheRead += cacheReadTokens
                    totalEstimatedCost += estimatedCost
                    sessionCount += 1
                    mergeDailyTotals(&dailyTotals, with: daily)
                    mergeNamedTotals(&modelTotals, with: models)
                    mergeNamedTotals(&originTotals, with: origins)

                    if let minDate = dates.min(), minDate < earliestDate {
                        earliestDate = minDate
                    }
                    if let maxDate = dates.max(), maxDate > latestDate {
                        latestDate = maxDate
                    }
                }
            }
        }

        guard totalInput > 0 || totalOutput > 0 || totalCacheCreation > 0 || totalCacheRead > 0 else { return nil }

        let pricing = ModelPricing.claude(for: nil)
        let fallbackCost = Self.calculateCost(
            input: totalInput,
            output: totalOutput,
            cacheCreation: totalCacheCreation,
            cacheRead: totalCacheRead,
            pricing: pricing
        )
        let cost = totalEstimatedCost > 0 ? totalEstimatedCost : fallbackCost

        return (TokenCost(
            provider: .claudeCode,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead,
            estimatedCostUSD: cost,
            sessionCount: sessionCount,
            periodStart: earliestDate,
            periodEnd: latestDate,
            modelBreakdowns: Self.makeBreakdowns(from: modelTotals, provider: .claudeCode, pricing: pricing),
            originBreakdowns: Self.makeBreakdowns(from: originTotals, provider: .claudeCode, pricing: pricing)
        ), Self.makeDailyUsage(from: dailyTotals, provider: .claudeCode, pricing: pricing))
    }

    nonisolated private static func claudeProjectRoots(accounts: [ClaudeCodeAccount]) -> [URL] {
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
                Self.claudeProjectsURL(forConfigPath: String(part))
            })
        }

        roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))

        for account in accounts {
            guard let configDirectory = account.configDirectory else { continue }
            roots.append(Self.claudeProjectsURL(forConfigPath: configDirectory))
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
            guard Self.isLocalDirectory(standardized),
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    nonisolated private static func claudeProjectsURL(forConfigPath rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: (trimmed as NSString).standardizingPath)
        if url.lastPathComponent == "projects" {
            return url
        }
        return url.appendingPathComponent("projects", isDirectory: true)
    }

    nonisolated static func parseSessionFile(
        at url: URL,
        since cutoffDate: Date
    ) -> (
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        estimatedCost: Double,
        dates: [Date],
        daily: [Date: TokenAccumulator],
        models: [String: TokenAccumulator],
        origins: [String: TokenAccumulator]
    ) {
        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var totalEstimatedCost = 0.0
        var dates: [Date] = []
        var dailyTotals: [Date: TokenAccumulator] = [:]
        var modelTotals: [String: TokenAccumulator] = [:]
        var originTotals: [String: TokenAccumulator] = [:]
        var keyedEvents: [String: ClaudeUsageEvent] = [:]
        var unkeyedEvents: [ClaudeUsageEvent] = []

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return (0, 0, 0, 0, 0, [], [:], [:], [:])
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let timestampStr = json["timestamp"] as? String,
                  let timestamp = FlexibleISO8601.date(from: timestampStr),
                  timestamp >= cutoffDate else {
                continue
            }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let event = ClaudeUsageEvent(
                    timestamp: timestamp,
                    model: message["model"] as? String,
                    messageID: message["id"] as? String,
                    requestID: json["requestId"] as? String,
                    input: intValue(usage["input_tokens"]),
                    output: intValue(usage["output_tokens"]),
                    cacheCreation: intValue(usage["cache_creation_input_tokens"]),
                    cacheCreationOneHour: Self.claudeOneHourCacheCreationTokens(in: usage),
                    cacheRead: intValue(usage["cache_read_input_tokens"]),
                    origin: Self.claudeUsageOrigin(json: json, message: message, url: url)
                )

                guard event.hasUsage else { continue }

                if let key = event.deduplicationKey {
                    keyedEvents[key] = event
                } else {
                    unkeyedEvents.append(event)
                }
            }
        }

        let events = keyedEvents.keys.sorted().compactMap { keyedEvents[$0] } + unkeyedEvents
        for event in events {
            let pricing = Self.claudePricing(for: event.model)
            let eventCost = Self.calculateClaudeCost(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheCreationOneHour: event.cacheCreationOneHour,
                cacheRead: event.cacheRead,
                pricing: pricing
            )
            let day = Calendar.current.startOfDay(for: event.timestamp)

            totalInput += event.input
            totalOutput += event.output
            totalCacheCreation += event.cacheCreation
            totalCacheRead += event.cacheRead
            totalEstimatedCost += eventCost
            dates.append(event.timestamp)
            dailyTotals[day, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            modelTotals[Self.displayModelName(event.model), default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
            originTotals[event.origin, default: TokenAccumulator()].add(
                input: event.input,
                output: event.output,
                cacheCreation: event.cacheCreation,
                cacheRead: event.cacheRead,
                estimatedCostUSD: eventCost
            )
        }

        return (totalInput, totalOutput, totalCacheCreation, totalCacheRead, totalEstimatedCost,
                dates, dailyTotals, modelTotals, originTotals)
    }

    nonisolated private static func claudeOneHourCacheCreationTokens(in usage: [String: Any]) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
        let total = intValue(usage["cache_creation_input_tokens"])
        let oneHour = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        return min(total, max(0, oneHour))
    }

    nonisolated static func claudePricing(for model: String?) -> TokenPricing {
        ModelPricing.claude(for: model)
    }

    nonisolated static func normalizeClaudeModel(_ raw: String) -> String {
        ModelPricing.normalizeClaudeModel(raw)
    }

    nonisolated private static func scanCodexSessions(since cutoffDate: Date) -> (TokenCost, [DailyTokenUsage])? {
        let codexDir = URL(fileURLWithPath: CodexHomeDirectory.path(), isDirectory: true)
        let archivedDir = codexDir.appendingPathComponent("archived_sessions")
        let logsDatabase = codexDir.appendingPathComponent("logs_2.sqlite")
        var context = CodexScanContext(earliestDate: Date(), latestDate: cutoffDate)

        Self.scanCodexArchivedSessions(directory: archivedDir, since: cutoffDate, context: &context)
        Self.scanCodexSQLiteLogs(database: logsDatabase, since: cutoffDate, context: &context)

        let totals = context.totals
        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        let pricing = ModelPricing.codex
        let billableInput = max(0, totals.input - totals.cacheRead)
        let output = totals.output + totals.reasoning
        let cost = Self.calculateCost(
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
            modelBreakdowns: Self.makeBreakdowns(from: context.modelTotals, provider: .codexCli, pricing: pricing),
            originBreakdowns: Self.makeBreakdowns(from: context.originTotals, provider: .codexCli, pricing: pricing)
        ), Self.makeDailyUsage(from: context.dailyTotals, provider: .codexCli, pricing: pricing))
    }

    /// Internal (not private) so the archived-session parsing — the Codex
    /// counterpart to `parseSessionFile`, and where CLI-vs-app cost divergence
    /// hides — can be fixture-tested against a temp directory.
    nonisolated static func scanCodexArchivedSessions(
        directory: URL,
        since cutoffDate: Date,
        context: inout CodexScanContext
    ) {
        guard Self.isLocalDirectory(directory) else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoffDate,
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            for line in content.split(separator: "\n") {
                guard line.contains("\"token_count\""),
                      let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampText = json["timestamp"] as? String,
                      let timestamp = FlexibleISO8601.date(from: timestampText),
                      timestamp >= cutoffDate,
                      let payload = json["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = (info["last_token_usage"] ?? info["total_token_usage"]) as? [String: Any] else {
                    continue
                }

                let sessionID = (((payload["rate_limits"] as? [String: Any])?["conversation_id"] as? String)
                    ?? fileURL.deletingPathExtension().lastPathComponent)
                Self.addCodexUsage(
                    usage,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    modelName: Self.codexModelName(from: info, payload: payload),
                    originName: "Codex CLI",
                    context: &context
                )
            }
        }
    }

    nonisolated private static func isLocalDirectory(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let values = try? standardized.resourceValues(forKeys: [.volumeIsLocalKey])
        // Intentionally skip network and mounted volumes; cost scans should stay
        // fast and avoid surprising remote I/O when users point accounts there.
        return values?.volumeIsLocal != false
    }

    nonisolated private static func scanCodexSQLiteLogs(
        database: URL,
        since cutoffDate: Date,
        context: inout CodexScanContext
    ) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

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
            guard let timestamp = Self.codexLogDate(in: body), timestamp >= cutoffDate else { continue }

            let usage: [String: Any] = [
                "input_tokens": Self.codexLogInt("input_token_count", in: body),
                "output_tokens": Self.codexLogInt("output_token_count", in: body),
                "cached_input_tokens": Self.codexLogInt("cached_token_count", in: body),
                "reasoning_output_tokens": Self.codexLogInt("reasoning_token_count", in: body)
            ]
            let sessionID = Self.codexLogValue("conversation.id", in: body)
                ?? Self.codexLogValue("thread.id", in: body)
                ?? "codex"
            Self.addCodexUsage(
                usage,
                timestamp: timestamp,
                sessionID: sessionID,
                modelName: Self.codexLogValue("model", in: body) ?? Self.codexLogValue("slug", in: body),
                originName: Self.codexLogValue("originator", in: body) ?? "Codex CLI",
                context: &context
            )
        }
    }

    nonisolated private static func addCodexUsage(
        _ usage: [String: Any],
        timestamp: Date,
        sessionID: String,
        modelName: String?,
        originName: String?,
        context: inout CodexScanContext
    ) {
        let input = intValue(usage["input_tokens"])
        let cached = intValue(usage["cached_input_tokens"])
        let output = intValue(usage["output_tokens"])
        let reasoning = intValue(usage["reasoning_output_tokens"])
        guard input > 0 || output > 0 || cached > 0 || reasoning > 0 else { return }

        // Use whole-millisecond precision for the dedup key so equivalent events
        // produce a stable, collision-resistant string (raw Double formatting can
        // vary and risks both false matches and false misses).
        let timestampMillis = Int((timestamp.timeIntervalSince1970 * 1000).rounded())
        let key = "\(timestampMillis)-\(sessionID)-\(input)-\(cached)-\(output)-\(reasoning)"
        guard context.eventKeys.insert(key).inserted else { return }

        context.sessionIDs.insert(sessionID)
        context.totals.add(input: input, output: output, cacheCreation: 0, cacheRead: cached, reasoning: reasoning)
        let day = Calendar.current.startOfDay(for: timestamp)
        context.dailyTotals[day, default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        context.modelTotals[Self.displayModelName(modelName), default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        context.originTotals[Self.displayOriginName(originName), default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        if timestamp < context.earliestDate { context.earliestDate = timestamp }
        if timestamp > context.latestDate { context.latestDate = timestamp }
    }

    nonisolated private static func makeDailyUsage(
        from dailyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [DailyTokenUsage] {
        dailyTotals.map { day, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : Self.calculateCost(
                    input: billableInput,
                    output: tokens.output + tokens.reasoning,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: pricing
                )
            return DailyTokenUsage(
                date: day,
                provider: provider,
                inputTokens: billableInput,
                outputTokens: tokens.output + tokens.reasoning,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost
            )
        }
    }

    nonisolated private static func makeBreakdowns(
        from totals: [String: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [TokenUsageBreakdown] {
        totals.map { name, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let output = tokens.output + tokens.reasoning
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : Self.calculateCost(
                    input: billableInput,
                    output: output,
                    cacheCreation: tokens.cacheCreation,
                    cacheRead: tokens.cacheRead,
                    pricing: pricing
                )
            return TokenUsageBreakdown(
                provider: provider,
                name: name,
                inputTokens: billableInput,
                outputTokens: output,
                cacheCreationTokens: tokens.cacheCreation,
                cacheReadTokens: tokens.cacheRead,
                estimatedCostUSD: cost,
                sessionCount: tokens.events
            )
        }
        .sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }

    nonisolated private static func mergeDailyTotals(
        _ target: inout [Date: TokenAccumulator],
        with source: [Date: TokenAccumulator]
    ) {
        for (day, tokens) in source {
            target[day, default: TokenAccumulator()].merge(tokens)
        }
    }

    nonisolated private static func mergeNamedTotals(
        _ target: inout [String: TokenAccumulator],
        with source: [String: TokenAccumulator]
    ) {
        for (name, tokens) in source {
            target[name, default: TokenAccumulator()].merge(tokens)
        }
    }

    nonisolated private static func claudeUsageOrigin(json: [String: Any], message: [String: Any], url: URL) -> String {
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

    nonisolated private static func codexModelName(from info: [String: Any], payload: [String: Any]) -> String? {
        (info["model"] as? String)
            ?? (info["slug"] as? String)
            ?? (payload["model"] as? String)
            ?? (payload["slug"] as? String)
    }

    nonisolated private static func displayModelName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown model" : Self.normalizeClaudeModel(trimmed)
    }

    nonisolated private static func displayOriginName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unknown origin" }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Cost without a one-hour cache tier — delegates to `calculateClaudeCost`
    /// so there is exactly one pricing formula. (These were near-duplicates
    /// that had drifted: only the Claude variant clamped negative inputs.)
    nonisolated static func calculateCost(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        pricing: TokenPricing
    ) -> Double {
        Self.calculateClaudeCost(
            input: input,
            output: output,
            cacheCreation: cacheCreation,
            cacheCreationOneHour: 0,
            cacheRead: cacheRead,
            pricing: pricing
        )
    }

    nonisolated static func calculateClaudeCost(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheCreationOneHour: Int,
        cacheRead: Int,
        pricing: TokenPricing
    ) -> Double {
        let oneHourCacheCreation = min(max(0, cacheCreationOneHour), max(0, cacheCreation))
        let fiveMinuteCacheCreation = max(0, cacheCreation - oneHourCacheCreation)
        let oneHourRate = pricing.cacheCreationOneHour ?? pricing.cacheCreation

        let inputCost = Double(max(0, input)) / 1_000_000 * pricing.input
        let outputCost = Double(max(0, output)) / 1_000_000 * pricing.output
        let cacheCreationCost = Double(fiveMinuteCacheCreation) / 1_000_000 * pricing.cacheCreation
        let oneHourCacheCreationCost = Double(oneHourCacheCreation) / 1_000_000 * oneHourRate
        let cacheReadCost = Double(max(0, cacheRead)) / 1_000_000 * pricing.cacheRead
        return inputCost + outputCost + cacheCreationCost + oneHourCacheCreationCost + cacheReadCost
    }

    nonisolated private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    nonisolated private static func codexLogDate(in text: String) -> Date? {
        guard let value = Self.codexLogValue("event.timestamp", in: text) else { return nil }
        return FlexibleISO8601.date(from: value)
    }

    nonisolated private static func codexLogInt(_ key: String, in text: String) -> Int {
        guard let value = Self.codexLogValue(key, in: text) else { return 0 }
        return Int(value) ?? 0
    }

    nonisolated private static func codexLogValue(_ key: String, in text: String) -> String? {
        let regex: NSRegularExpression
        if let cached = Self.codexLogValueRegexes[key] {
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

/// Mutable accumulators threaded through the Codex scan. Bundling these into one
/// value collapses `addCodexUsage`/`scanCodexArchivedSessions`/`scanCodexSQLiteLogs`
/// from 10–13 parameters (a SwiftLint `function_parameter_count` error) down to
/// a single `inout` argument.
///
/// Internal (not private) so `scanCodexArchivedSessions` can be fixture-tested.
nonisolated struct CodexScanContext: Sendable {
    var totals = TokenAccumulator()
    var dailyTotals: [Date: TokenAccumulator] = [:]
    var modelTotals: [String: TokenAccumulator] = [:]
    var originTotals: [String: TokenAccumulator] = [:]
    var eventKeys: Set<String> = []
    var sessionIDs: Set<String> = []
    var earliestDate: Date
    var latestDate: Date
}

nonisolated struct TokenAccumulator: Sendable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var reasoning = 0
    var estimatedCostUSD = 0.0
    var events = 0

    mutating func add(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int = 0,
        estimatedCostUSD: Double = 0,
        events: Int = 1
    ) {
        self.input += input
        self.output += output
        self.cacheCreation += cacheCreation
        self.cacheRead += cacheRead
        self.reasoning += reasoning
        self.estimatedCostUSD += estimatedCostUSD
        self.events += events
    }

    mutating func merge(_ other: TokenAccumulator) {
        add(
            input: other.input,
            output: other.output,
            cacheCreation: other.cacheCreation,
            cacheRead: other.cacheRead,
            reasoning: other.reasoning,
            estimatedCostUSD: other.estimatedCostUSD,
            events: other.events
        )
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
