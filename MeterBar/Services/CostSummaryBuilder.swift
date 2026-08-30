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
            self.deferredProviders = deferredProviders
            self.summary = summary.recordingLocalScanCompletion(deferredProviders.isEmpty)
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
    /// The published summary is the visible period only. Lifetime totals used
    /// to force a walk of every archived transcript; they are no longer filled.
    ///
    /// `enabledProviders` replaces what used to be one `Bool` per provider: with
    /// three corpora that shape had grown to three flags whose order at the call
    /// site was load-bearing, and a set states the same thing without letting a
    /// fourth provider silently push the argument list past the linter's cap.
    ///
    /// `usageLedger` carries the providers that have no corpus to scan at all.
    /// Cursor and OpenRouter publish a running counter and no session log, so
    /// their rows come from MeterBar's own poll history rather than from disk —
    /// see `ProviderUsageLedger`. It arrives pre-filtered to the enabled
    /// services (there is no `CostScanProvider` case to test against, and adding
    /// one would drag a poll into the byte-offset deferral machinery it has no
    /// use for).
    nonisolated static func makeScan(
        days: Int,
        enabledProviders: Set<CostScanProvider>,
        claudeAccounts: [ClaudeCodeAccount],
        grokAccounts: [GrokAccount],
        session: CostScanSession,
        claudeProjectRoots: [URL]? = nil,
        usageLedger: ProviderUsageLedger = ProviderUsageLedger()
    ) -> CostSummaryScan {
        var scan = ScanWindows(
            period: CostScanResult(),
            lifetime: CostScanResult(),
            cutoff: session.cutoff
        )

        if enabledProviders.contains(.claude) {
            let roots = claudeProjectRoots ?? ClaudeCostScanner.projectRoots(accounts: claudeAccounts)
            let claude = ClaudeCostScanner.scanRoots(roots, session: session)
            scan.period.append(ClaudeCostScanner.makeCost(from: claude.period, windowStart: session.cutoff))
            scan.period.record(claude.period.pricing)
        }

        if enabledProviders.contains(.codex) {
            let codex = CodexCostScanner.scanSessions(session: session)
            scan.period.append(CodexCostScanner.makeCost(from: codex.period))
            scan.period.record(codex.period.pricing)
        }

        // No `record(...)` pass: Grok bills each turn itself, so its rows are
        // never priced from the local table and have no provenance to report.
        if enabledProviders.contains(.grok) {
            let roots = GrokCostScanner.sessionRoots(accounts: grokAccounts)
            let grok = GrokCostScanner.scanRoots(roots, session: session)
            scan.period.append(GrokCostScanner.makeCost(from: grok.period))
        }

        // No pricing pass either: these totals arrive already denominated in
        // dollars by the provider, so no local rate priced them and there is no
        // provenance to report. Providers denominated in requests never reach
        // here — `usdProviders` is the guard, and it is the only one between a
        // Cursor request count and `estimatedCostUSD`.
        for provider in usageLedger.usdProviders {
            scan.period.append(
                ProviderUsageCostBuilder.makeCost(
                    from: usageLedger,
                    provider: provider,
                    windowStart: session.cutoff
                )
            )
        }

        // Events older than every entry in the table were priced at the oldest
        // known rate — a documented guess, so say so rather than let it pass as
        // a verified figure (issue #339).
        if let note = scan.period.pricing.diagnosticNote {
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
                hourlyUsage: scan.period.hourlyUsage.sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date < rhs.date }
                    return lhs.provider.rawValue < rhs.provider.rawValue
                },
                lifetime: nil,
                pricing: scan.period.pricing.isEmpty ? nil : scan.period.pricing
            ),
            deferredProviders: session.deferredProviders
        )
    }
}
