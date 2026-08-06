import Foundation
import MeterBarShared
import os

/// Runs the per-provider scanners and folds their windows into the published
/// `CostSummary`. Split out of `CostTracker` (audit C1d) so the summary shape
/// can be exercised without an `ObservableObject`.
enum CostSummaryBuilder {
    nonisolated static func makeSummary(
        days: Int,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> CostSummary {
        let cutoffDate = CostWindow.start(days: days)
        // One traversal fills both windows. The lifetime scan reads a strict
        // superset of the period scan, so running it separately meant reading
        // every transcript twice for the same numbers.
        let scan = Self.scanSources(
            since: cutoffDate,
            includeClaudeCode: includeClaudeCode,
            includeCodexCli: includeCodexCli,
            claudeAccounts: claudeAccounts
        )

        let costs = scan.period.costs
        let totalCostUSD: Double = costs.reduce(0) { $0 + $1.estimatedCostUSD }
        let totalTokens: Int = costs.reduce(0) { $0 + $1.totalTokens }

        return CostSummary(
            costs: costs,
            totalCostUSD: totalCostUSD,
            totalTokens: totalTokens,
            periodDays: days,
            dailyUsage: scan.period.dailyUsage.sorted { $0.date < $1.date },
            lifetime: LifetimeCostSummary(costs: scan.lifetime.costs),
            pricing: scan.period.pricing.isEmpty ? nil : scan.period.pricing
        )
    }

    nonisolated private static func scanSources(
        since cutoffDate: Date,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount]
    ) -> ScanWindows<CostScanResult> {
        var scan = ScanWindows(period: CostScanResult(), lifetime: CostScanResult(), cutoff: cutoffDate)

        if includeClaudeCode {
            let claude = ClaudeCostScanner.scanSessions(since: cutoffDate, claudeAccounts: claudeAccounts)
            scan.period.append(ClaudeCostScanner.makeCost(from: claude.period, windowStart: cutoffDate))
            scan.lifetime.append(ClaudeCostScanner.makeCost(from: claude.lifetime, windowStart: .distantPast))
            scan.period.record(claude.period.pricing)
            scan.lifetime.record(claude.lifetime.pricing)
        }

        if includeCodexCli {
            let codex = CodexCostScanner.scanSessions(since: cutoffDate)
            scan.period.append(CodexCostScanner.makeCost(from: codex.period))
            scan.lifetime.append(CodexCostScanner.makeCost(from: codex.lifetime))
            scan.period.record(codex.period.pricing)
            scan.lifetime.record(codex.lifetime.pricing)
        }

        // Events older than every entry in the table were priced at the oldest
        // known rate — a documented guess, so say so rather than let it pass as
        // a verified figure (issue #339).
        if let note = scan.lifetime.pricing.diagnosticNote {
            AppLog.cost.warning("Pricing table gap: \(note, privacy: .public)")
        }

        return scan
    }
}
