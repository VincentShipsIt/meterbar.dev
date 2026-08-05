import Foundation

/// Runs the per-provider scanners and folds their windows into the published
/// `CostSummary`. Split out of `CostTracker` (audit C1d) so the summary shape
/// can be exercised without an `ObservableObject`.
enum CostSummaryBuilder {
    nonisolated static func makeSummary(
        days: Int,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount],
        scanCacheURL: URL? = CostScanCacheStore.cacheURL
    ) -> CostSummary {
        let cutoffDate = CostWindow.start(days: days)
        // Transcripts are append-only and mostly frozen, so a repeat scan
        // re-derives the same totals from the same bytes. The cache holds the
        // previous run's per-file results and hands them back whenever size,
        // mtime, and file ID all still match.
        let cache = scanCacheURL.map { CostScanCache.load(from: $0) }
        // One traversal fills both windows. The lifetime scan reads a strict
        // superset of the period scan, so running it separately meant reading
        // every transcript twice for the same numbers.
        let scan = Self.scanSources(
            since: cutoffDate,
            includeClaudeCode: includeClaudeCode,
            includeCodexCli: includeCodexCli,
            claudeAccounts: claudeAccounts,
            cache: cache
        )

        if let cache, let scanCacheURL {
            // A provider turned off in Settings is not scanned, so nothing
            // records its files this pass. Without this, disabling it would
            // discard a valid cache and make re-enabling it a full re-parse.
            if !includeClaudeCode { cache.carryForwardClaudeEntries() }
            if !includeCodexCli { cache.carryForwardCodexEntries() }
            cache.persist(to: scanCacheURL)
        }

        let costs = scan.period.costs
        let totalCostUSD: Double = costs.reduce(0) { $0 + $1.estimatedCostUSD }
        let totalTokens: Int = costs.reduce(0) { $0 + $1.totalTokens }

        return CostSummary(
            costs: costs,
            totalCostUSD: totalCostUSD,
            totalTokens: totalTokens,
            periodDays: days,
            dailyUsage: scan.period.dailyUsage.sorted { $0.date < $1.date },
            lifetime: LifetimeCostSummary(costs: scan.lifetime.costs)
        )
    }

    nonisolated private static func scanSources(
        since cutoffDate: Date,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount],
        cache: CostScanCache?
    ) -> ScanWindows<CostScanResult> {
        var scan = ScanWindows(period: CostScanResult(), lifetime: CostScanResult(), cutoff: cutoffDate)

        if includeClaudeCode {
            let claude = ClaudeCostScanner.scanSessions(
                since: cutoffDate,
                claudeAccounts: claudeAccounts,
                cache: cache
            )
            scan.period.append(ClaudeCostScanner.makeCost(from: claude.period, windowStart: cutoffDate))
            scan.lifetime.append(ClaudeCostScanner.makeCost(from: claude.lifetime, windowStart: .distantPast))
        }

        if includeCodexCli {
            let codex = CodexCostScanner.scanSessions(since: cutoffDate, cache: cache)
            scan.period.append(CodexCostScanner.makeCost(from: codex.period))
            scan.lifetime.append(CodexCostScanner.makeCost(from: codex.lifetime))
        }

        return scan
    }
}
