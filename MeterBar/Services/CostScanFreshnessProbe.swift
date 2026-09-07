import Foundation
import MeterBarShared

/// Cheap disk-evidence probe backing `CostSummary`'s "already scanned" gate
/// (issue #517).
///
/// The gate used to trust `lastScanDate` for the rest of the calendar day —
/// so a scan at 12:55 permanently froze the sparkline even after hundreds of
/// megatokens landed at 15:11, because "a scan ran today" is not the same
/// claim as "the cache is current." This probe answers the real question:
/// has anything on disk changed since the last scan? It reuses
/// `CostScanCorpus.listing`'s per-file stat — `modifiedSince` is exactly the
/// filter the scanners already apply on every real refresh — rather than
/// adding a second directory walk or reading any transcript bytes.
nonisolated enum CostScanFreshnessProbe {
    /// Whether any enabled provider's transcripts changed after `lastScanDate`.
    ///
    /// Resolves the same roots a real scan would (`ClaudeCostScanner`,
    /// `CodexCostScanner`, `GrokCostScanner`), so this is the production
    /// default `CostTracker.needsBackgroundRefresh` injects. Tests should
    /// inject their own closure rather than call this directly — it reads
    /// real account stores and home directories.
    ///
    /// - Returns: `true`/`false` when every enabled provider's roots could be
    ///   walked in full; `nil` when at least one could not (an unreadable
    ///   directory) — callers fall back to a time-based staleness threshold
    ///   in that case.
    static func hasNewTranscripts(
        since lastScanDate: Date,
        enabledServices: Set<ServiceType>
    ) -> Bool? {
        let providers = CostScanProvider.allCases.filter { enabledServices.contains($0.service) }
        guard !providers.isEmpty else { return false }

        var sawIncompleteWalk = false
        for provider in providers {
            let evidence = hasNewTranscripts(
                in: roots(for: provider),
                since: lastScanDate,
                fileNames: fileNames(for: provider)
            )
            switch evidence {
            case .some(true):
                return true
            case .some(false):
                continue
            case nil:
                sawIncompleteWalk = true
            }
        }
        return sawIncompleteWalk ? nil : false
    }

    /// The root-walking half of the probe, kept separate from provider/account
    /// resolution so it is testable against a temp directory instead of the
    /// developer's real `~/.claude` / `~/.codex` / `~/.grok`.
    ///
    /// - Returns: `true` when a root holds a file modified after `date`,
    ///   `false` when every root was walked in full and none did, `nil` when
    ///   a root could not be walked (an unreadable directory) — the caller
    ///   cannot tell whether that root is hiding new evidence.
    static func hasNewTranscripts(
        in roots: [URL],
        since date: Date,
        fileNames: Set<String>? = nil
    ) -> Bool? {
        var sawIncompleteWalk = false
        for root in roots {
            guard CostScanFileSystem.isLocalDirectory(root) else { continue }
            let listing = CostScanCorpus.listing(in: root, modifiedSince: date, fileNames: fileNames)
            if !listing.files.isEmpty { return true }
            if !listing.isComplete { sawIncompleteWalk = true }
        }
        return sawIncompleteWalk ? nil : false
    }

    private static func roots(for provider: CostScanProvider) -> [URL] {
        switch provider {
        case .claude:
            ClaudeCostScanner.projectRoots(accounts: ClaudeCodeAccountStore.shared.accounts)
        case .codex:
            CodexCostScanner.rolloutDirectories(
                in: URL(fileURLWithPath: CodexHomeDirectory.path(), isDirectory: true)
            )
        case .grok:
            GrokCostScanner.sessionRoots(accounts: GrokAccountStore.shared.accounts)
        }
    }

    /// Mirrors the name filter each scanner applies to its own roots (issue
    /// #372's Grok scan only ever reads `updates.jsonl`); without it the probe
    /// would treat an unrelated file in the same directory as evidence.
    private static func fileNames(for provider: CostScanProvider) -> Set<String>? {
        switch provider {
        case .claude, .codex: nil
        case .grok: ["updates.jsonl"]
        }
    }
}
