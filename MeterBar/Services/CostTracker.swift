import Combine
import MeterBarShared
import Foundation
import os
import SQLite3

class CostTracker: ObservableObject {
    static let shared = CostTracker()

    @Published var costSummary: CostSummary?
    @Published var isScanning: Bool = false
    @Published var isRefreshingMissingDays: Bool = false
    @Published var lastScanDate: Date?

    private let providerVisibilityStore = ProviderVisibilityStore.shared
    private let cacheFileName = "cost-summary-v1.json"

    /// True while either a manual scan or a background missing-day backfill runs.
    var isRefreshInProgress: Bool {
        isScanning || isRefreshingMissingDays
    }

    // API-rate estimates per million tokens for local log usage.
    private let pricing: [String: TokenPricing] = [
        "claude-sonnet": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30),
        "claude-opus": TokenPricing(input: 15.0, output: 75.0, cacheCreation: 18.75, cacheRead: 1.50),
        "claude-haiku": TokenPricing(input: 0.25, output: 1.25, cacheCreation: 0.30, cacheRead: 0.03),
        "claude-fable-5": TokenPricing(input: 10.0, output: 50.0, cacheCreation: 12.5, cacheRead: 1.0, cacheCreationOneHour: 20.0),
        "claude-opus-4-8": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-7": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-opus-4-6": TokenPricing(input: 5.0, output: 25.0, cacheCreation: 6.25, cacheRead: 0.50, cacheCreationOneHour: 10.0),
        "claude-sonnet-4-6": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4-5": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-sonnet-4": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30, cacheCreationOneHour: 6.0),
        "claude-haiku-4-5": TokenPricing(input: 1.0, output: 5.0, cacheCreation: 1.25, cacheRead: 0.10, cacheCreationOneHour: 2.0),
        "codex": TokenPricing(input: 1.25, output: 10.0, cacheCreation: 0, cacheRead: 0.125),
        "default": TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)
    ]

    /// Non-optional fallback so pricing lookups never need a force-unwrap of
    /// `pricing["default"]`. Mirrors the `"default"` entry above.
    private let defaultPricing = TokenPricing(input: 3.0, output: 15.0, cacheCreation: 3.75, cacheRead: 0.30)

    // Cached formatters/regexes. The scan parses tens of thousands of log lines,
    // so allocating an ISO8601DateFormatter/NSRegularExpression per call was a
    // measurable hot-path cost. `ISO8601DateFormatter.date(from:)` and
    // `NSRegularExpression` are safe to share across reads.
    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let codexLogValueRegexes: [String: NSRegularExpression] = {
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

    private init() {
        loadCachedSummary()
    }

    func scanCosts(days: Int = 30) async {
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

    /// Quietly backfills missing daily rows when Overview/Costs opens, without the
    /// visible "Scanning" UI a manual scan shows. No-ops unless the cached summary
    /// actually has gaps in the visible window (see `needsMissingDailyUsageRefresh`).
    func refreshMissingDaysInBackground(days: Int = 30) async {
        let shouldStart = await MainActor.run {
            guard !isRefreshInProgress,
                  let visibleSummary = costSummary?.filtered(to: providerVisibilityStore.enabledServices),
                  visibleSummary.needsMissingDailyUsageRefresh(days: days, lastScanDate: lastScanDate) else {
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
        return await Task.detached(priority: priority) { [self] in
            buildCostSummary(
                days: days,
                includeClaudeCode: includeClaudeCode,
                includeCodexCli: includeCodexCli,
                claudeAccounts: claudeAccounts
            )
        }.value
    }

    private func buildCostSummary(
        days: Int,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> CostSummary {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var allCosts: [TokenCost] = []
        var dailyUsage: [DailyTokenUsage] = []

        // Scan Claude Code sessions
        if includeClaudeCode,
           let (claudeCost, claudeDailyUsage) = scanClaudeCodeSessions(
            since: cutoffDate,
            claudeAccounts: claudeAccounts
           ) {
            allCosts.append(claudeCost)
            dailyUsage.append(contentsOf: claudeDailyUsage)
        }

        if includeCodexCli,
           let (codexCost, codexDailyUsage) = scanCodexSessions(since: cutoffDate) {
            allCosts.append(codexCost)
            dailyUsage.append(contentsOf: codexDailyUsage)
        }

        // Calculate summary
        let totalCost = allCosts.reduce(0) { $0 + $1.estimatedCostUSD }
        let totalTokens = allCosts.reduce(0) { $0 + $1.totalTokens }

        return CostSummary(
            costs: allCosts,
            totalCostUSD: totalCost,
            totalTokens: totalTokens,
            periodDays: days,
            dailyUsage: dailyUsage.sorted { $0.date < $1.date }
        )
    }

    private var cacheURL: URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return supportDirectory
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    private func loadCachedSummary() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let cache = try decoder.decode(CostSummaryCache.self, from: data)
            costSummary = cache.summary
            lastScanDate = cache.lastScanDate
        } catch {
            AppLog.cost.error("Failed to load cost summary cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveCachedSummary() {
        guard let costSummary,
              let cacheURL,
              let lastScanDate else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(CostSummaryCache(summary: costSummary, lastScanDate: lastScanDate))
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
            AppLog.cost.error("Failed to save cost summary cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scanClaudeCodeSessions(
        since cutoffDate: Date,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> (TokenCost, [DailyTokenUsage])? {
        let projectRoots = claudeProjectRoots(accounts: claudeAccounts)
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

                let (input, output, cacheCreate, cacheReadTokens, estimatedCost, dates, daily, models, origins) = parseSessionFile(
                    at: url,
                    since: cutoffDate
                )

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

        let pricing = self.pricing["claude-sonnet"] ?? defaultPricing
        let fallbackCost = calculateCost(
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
            modelBreakdowns: makeBreakdowns(from: modelTotals, provider: .claudeCode, pricing: pricing),
            originBreakdowns: makeBreakdowns(from: originTotals, provider: .claudeCode, pricing: pricing)
        ), makeDailyUsage(from: dailyTotals, provider: .claudeCode, pricing: pricing))
    }

    private func claudeProjectRoots(accounts: [ClaudeCodeAccount]) -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            roots.append(contentsOf: env.split(separator: ",").map { part in
                claudeProjectsURL(forConfigPath: String(part))
            })
        }

        roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))

        for account in accounts {
            guard let configDirectory = account.configDirectory else { continue }
            roots.append(claudeProjectsURL(forConfigPath: configDirectory))
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
            guard fileManager.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    private func claudeProjectsURL(forConfigPath rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: (trimmed as NSString).standardizingPath)
        if url.lastPathComponent == "projects" {
            return url
        }
        return url.appendingPathComponent("projects", isDirectory: true)
    }

    private func parseSessionFile(
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
                  let timestamp = parseISO8601(timestampStr),
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
                    cacheCreationOneHour: claudeOneHourCacheCreationTokens(in: usage),
                    cacheRead: intValue(usage["cache_read_input_tokens"]),
                    origin: claudeUsageOrigin(json: json, message: message, url: url)
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
            let pricing = claudePricing(for: event.model)
            let eventCost = calculateClaudeCost(
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
            modelTotals[displayModelName(event.model), default: TokenAccumulator()].add(
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

        return (totalInput, totalOutput, totalCacheCreation, totalCacheRead, totalEstimatedCost, dates, dailyTotals, modelTotals, originTotals)
    }

    private func parseISO8601(_ value: String) -> Date? {
        if let date = Self.fractionalISO8601Formatter.date(from: value) {
            return date
        }
        return Self.plainISO8601Formatter.date(from: value)
    }

    private func claudeOneHourCacheCreationTokens(in usage: [String: Any]) -> Int {
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else { return 0 }
        let total = intValue(usage["cache_creation_input_tokens"])
        let oneHour = intValue(cacheCreation["ephemeral_1h_input_tokens"])
        return min(total, max(0, oneHour))
    }

    private func claudePricing(for model: String?) -> TokenPricing {
        guard let model else {
            return pricing["claude-sonnet"] ?? defaultPricing
        }

        let normalized = normalizeClaudeModel(model)
        if let exact = pricing[normalized] {
            return exact
        }

        if normalized.contains("fable") {
            return pricing["claude-fable-5"] ?? defaultPricing
        }
        if normalized.contains("opus") {
            if normalized.contains("4-8") { return pricing["claude-opus-4-8"] ?? (pricing["claude-opus"] ?? defaultPricing) }
            if normalized.contains("4-7") { return pricing["claude-opus-4-7"] ?? (pricing["claude-opus"] ?? defaultPricing) }
            if normalized.contains("4-6") { return pricing["claude-opus-4-6"] ?? (pricing["claude-opus"] ?? defaultPricing) }
            return pricing["claude-opus"] ?? defaultPricing
        }
        if normalized.contains("haiku") {
            return normalized.contains("4-5")
                ? pricing["claude-haiku-4-5"] ?? (pricing["claude-haiku"] ?? defaultPricing)
                : pricing["claude-haiku"] ?? defaultPricing
        }
        if normalized.contains("sonnet") {
            if normalized.contains("4-6") { return pricing["claude-sonnet-4-6"] ?? (pricing["claude-sonnet"] ?? defaultPricing) }
            if normalized.contains("4-5") { return pricing["claude-sonnet-4-5"] ?? (pricing["claude-sonnet"] ?? defaultPricing) }
            if normalized.contains("4") { return pricing["claude-sonnet-4"] ?? (pricing["claude-sonnet"] ?? defaultPricing) }
            return pricing["claude-sonnet"] ?? defaultPricing
        }

        return defaultPricing
    }

    private func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }
        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-") {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }
        if let versionRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(versionRange)
        }
        // Strip a trailing `-YYYYMMDD` release-date suffix so dated model ids
        // (e.g. `claude-opus-4-8-20260101`) normalize to their base id. This keeps
        // display names clean and lets pricing match new dated models too, not
        // only the ones already present in the pricing table.
        if let dateRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(trimmed[..<dateRange.lowerBound])
        }
        return trimmed
    }

    private func scanCodexSessions(since cutoffDate: Date) -> (TokenCost, [DailyTokenUsage])? {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let archivedDir = codexDir.appendingPathComponent("archived_sessions")
        let logsDatabase = codexDir.appendingPathComponent("logs_2.sqlite")
        var context = CodexScanContext(earliestDate: Date(), latestDate: cutoffDate)

        scanCodexArchivedSessions(directory: archivedDir, since: cutoffDate, context: &context)
        scanCodexSQLiteLogs(database: logsDatabase, since: cutoffDate, context: &context)

        let totals = context.totals
        guard totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 else { return nil }

        let pricing = self.pricing["codex"] ?? defaultPricing
        let billableInput = max(0, totals.input - totals.cacheRead)
        let output = totals.output + totals.reasoning
        let cost = calculateCost(
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
            modelBreakdowns: makeBreakdowns(from: context.modelTotals, provider: .codexCli, pricing: pricing),
            originBreakdowns: makeBreakdowns(from: context.originTotals, provider: .codexCli, pricing: pricing)
        ), makeDailyUsage(from: context.dailyTotals, provider: .codexCli, pricing: pricing))
    }

    private func scanCodexArchivedSessions(
        directory: URL,
        since cutoffDate: Date,
        context: inout CodexScanContext
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let formatter = Self.fractionalISO8601Formatter

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
                      let timestamp = formatter.date(from: timestampText),
                      timestamp >= cutoffDate,
                      let payload = json["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = (info["last_token_usage"] ?? info["total_token_usage"]) as? [String: Any] else {
                    continue
                }

                let sessionID = (((payload["rate_limits"] as? [String: Any])?["conversation_id"] as? String)
                    ?? fileURL.deletingPathExtension().lastPathComponent)
                addCodexUsage(
                    usage,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    modelName: codexModelName(from: info, payload: payload),
                    originName: "Codex CLI",
                    context: &context
                )
            }
        }
    }

    private func scanCodexSQLiteLogs(
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
            guard let timestamp = codexLogDate(in: body), timestamp >= cutoffDate else { continue }

            let usage: [String: Any] = [
                "input_tokens": codexLogInt("input_token_count", in: body),
                "output_tokens": codexLogInt("output_token_count", in: body),
                "cached_input_tokens": codexLogInt("cached_token_count", in: body),
                "reasoning_output_tokens": codexLogInt("reasoning_token_count", in: body)
            ]
            let sessionID = codexLogValue("conversation.id", in: body) ?? codexLogValue("thread.id", in: body) ?? "codex"
            addCodexUsage(
                usage,
                timestamp: timestamp,
                sessionID: sessionID,
                modelName: codexLogValue("model", in: body) ?? codexLogValue("slug", in: body),
                originName: codexLogValue("originator", in: body) ?? "Codex CLI",
                context: &context
            )
        }
    }

    private func addCodexUsage(
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
        context.modelTotals[displayModelName(modelName), default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        context.originTotals[displayOriginName(originName), default: TokenAccumulator()].add(
            input: input,
            output: output + reasoning,
            cacheCreation: 0,
            cacheRead: cached
        )
        if timestamp < context.earliestDate { context.earliestDate = timestamp }
        if timestamp > context.latestDate { context.latestDate = timestamp }
    }

    private func makeDailyUsage(
        from dailyTotals: [Date: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [DailyTokenUsage] {
        dailyTotals.map { day, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : calculateCost(
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

    private func makeBreakdowns(
        from totals: [String: TokenAccumulator],
        provider: ServiceType,
        pricing: TokenPricing
    ) -> [TokenUsageBreakdown] {
        totals.map { name, tokens in
            let billableInput = provider == .codexCli ? max(0, tokens.input - tokens.cacheRead) : tokens.input
            let output = tokens.output + tokens.reasoning
            let cost = tokens.estimatedCostUSD > 0
                ? tokens.estimatedCostUSD
                : calculateCost(
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

    private func mergeDailyTotals(_ target: inout [Date: TokenAccumulator], with source: [Date: TokenAccumulator]) {
        for (day, tokens) in source {
            target[day, default: TokenAccumulator()].merge(tokens)
        }
    }

    private func mergeNamedTotals(_ target: inout [String: TokenAccumulator], with source: [String: TokenAccumulator]) {
        for (name, tokens) in source {
            target[name, default: TokenAccumulator()].merge(tokens)
        }
    }

    private func claudeUsageOrigin(json: [String: Any], message: [String: Any], url: URL) -> String {
        if url.path.contains("/subagents/") || (json["isSidechain"] as? Bool == true) {
            return "Agents"
        }

        let toolNames = toolUseNames(in: message)
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

    private func toolUseNames(in message: [String: Any]) -> [String] {
        guard let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { item in
            guard item["type"] as? String == "tool_use" else { return nil }
            return item["name"] as? String
        }
    }

    private func codexModelName(from info: [String: Any], payload: [String: Any]) -> String? {
        (info["model"] as? String)
            ?? (info["slug"] as? String)
            ?? (payload["model"] as? String)
            ?? (payload["slug"] as? String)
    }

    private func displayModelName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown model" : normalizeClaudeModel(trimmed)
    }

    private func displayOriginName(_ raw: String?) -> String {
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

    private func calculateCost(input: Int, output: Int, cacheCreation: Int, cacheRead: Int, pricing: TokenPricing) -> Double {
        let inputCost = Double(input) / 1_000_000 * pricing.input
        let outputCost = Double(output) / 1_000_000 * pricing.output
        let cacheCreationCost = Double(cacheCreation) / 1_000_000 * pricing.cacheCreation
        let cacheReadCost = Double(cacheRead) / 1_000_000 * pricing.cacheRead
        return inputCost + outputCost + cacheCreationCost + cacheReadCost
    }

    private func calculateClaudeCost(
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

    private func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func codexLogDate(in text: String) -> Date? {
        guard let value = codexLogValue("event.timestamp", in: text) else { return nil }
        return Self.fractionalISO8601Formatter.date(from: value)
    }

    private func codexLogInt(_ key: String, in text: String) -> Int {
        guard let value = codexLogValue(key, in: text) else { return 0 }
        return Int(value) ?? 0
    }

    private func codexLogValue(_ key: String, in text: String) -> String? {
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

private struct CostSummaryCache: Codable {
    let summary: CostSummary
    let lastScanDate: Date
}

/// Mutable accumulators threaded through the Codex scan. Bundling these into one
/// value collapses `addCodexUsage`/`scanCodexArchivedSessions`/`scanCodexSQLiteLogs`
/// from 10–13 parameters (a SwiftLint `function_parameter_count` error) down to
/// a single `inout` argument.
private struct CodexScanContext {
    var totals = TokenAccumulator()
    var dailyTotals: [Date: TokenAccumulator] = [:]
    var modelTotals: [String: TokenAccumulator] = [:]
    var originTotals: [String: TokenAccumulator] = [:]
    var eventKeys: Set<String> = []
    var sessionIDs: Set<String> = []
    var earliestDate: Date
    var latestDate: Date
}

private struct TokenPricing {
    let input: Double      // per million tokens
    let output: Double     // per million tokens
    let cacheCreation: Double
    let cacheRead: Double
    let cacheCreationOneHour: Double?

    init(
        input: Double,
        output: Double,
        cacheCreation: Double,
        cacheRead: Double,
        cacheCreationOneHour: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreationOneHour = cacheCreationOneHour
    }
}

private struct TokenAccumulator {
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

private struct ClaudeUsageEvent {
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
