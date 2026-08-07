import Foundation
import MeterBarShared
import os

/// Runs the per-provider scanners and folds their windows into the published
/// `CostSummary`. Split out of `CostTracker` (audit C1d) so the summary shape
/// can be exercised without an `ObservableObject`.
enum CostSummaryBuilder {
    /// A summary plus whether the refresh that produced it saw the whole corpus.
    nonisolated struct CostSummaryScan: Sendable {
        let summary: CostSummary

        /// The providers whose corpus still has unread files, because the budget
        /// ran out or the refresh was cancelled. The summary is correct as far
        /// as it goes — every number in it comes from bytes actually accounted
        /// for — but it is not yet the whole corpus.
        ///
        /// Named per provider rather than as one flag so the caller can pair
        /// each with that provider's own persist outcome; see
        /// `CostTracker.shouldRunAnotherSlice`.
        let deferredProviders: Set<CostScanProvider>

        var isComplete: Bool { deferredProviders.isEmpty }

        init(summary: CostSummary, deferredProviders: Set<CostScanProvider> = []) {
            self.summary = summary
            self.deferredProviders = deferredProviders
        }
    }

    /// One budgeted slice of the corpus scan.
    ///
    /// Reads only what `session`'s budget allows, resuming each transcript from
    /// the byte offset the last slice committed. Files it does not reach still
    /// contribute their cached totals, so the summary is
    /// complete-as-of-what-has-been-read from the very first slice rather than
    /// only after the last one.
    ///
    /// One traversal fills both windows. The lifetime scan reads a strict
    /// superset of the period scan, so running it separately would mean reading
    /// every transcript twice for the same numbers.
    nonisolated static func makeScan(
        days: Int,
        includeClaudeCode: Bool,
        includeCodexCli: Bool,
        claudeAccounts: [ClaudeCodeAccount],
        session: CostScanSession,
        claudeProjectRoots: [URL]? = nil
    ) -> CostSummaryScan {
        var scan = ScanWindows(
            period: CostScanResult(),
            lifetime: CostScanResult(),
            cutoff: session.cutoff
        )

        if includeClaudeCode {
            let roots = claudeProjectRoots ?? ClaudeCostScanner.projectRoots(accounts: claudeAccounts)
            let claude = ClaudeCostScanner.scanRoots(roots, session: session)
            scan.period.append(ClaudeCostScanner.makeCost(from: claude.period, windowStart: session.cutoff))
            scan.lifetime.append(ClaudeCostScanner.makeCost(from: claude.lifetime, windowStart: .distantPast))
            scan.period.record(claude.period.pricing)
            scan.lifetime.record(claude.lifetime.pricing)
        }

        if includeCodexCli {
            let codex = CodexCostScanner.scanSessions(session: session)
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

        let costs = scan.period.costs
        return CostSummaryScan(
            summary: CostSummary(
                costs: costs,
                totalCostUSD: costs.reduce(0) { $0 + $1.estimatedCostUSD },
                totalTokens: costs.reduce(0) { $0 + $1.totalTokens },
                periodDays: days,
                dailyUsage: scan.period.dailyUsage.sorted { $0.date < $1.date },
                lifetime: LifetimeCostSummary(costs: scan.lifetime.costs),
                pricing: scan.period.pricing.isEmpty ? nil : scan.period.pricing
            ),
            deferredProviders: session.deferredProviders
        )
    }
}
