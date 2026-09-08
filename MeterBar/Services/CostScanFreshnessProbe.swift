import Foundation
import MeterBarShared

/// Cheap disk-evidence probe backing `CostSummary`'s "already scanned" gate
/// (issue #517).
///
/// The gate used to trust `lastScanDate` for the rest of the calendar day —
/// so a scan at 12:55 permanently froze the sparkline even after hundreds of
/// megatokens landed at 15:11, because "a scan ran today" is not the same
/// claim as "the cache is current." This probe answers the real question:
/// has anything on disk changed since the last scan?
///
/// Issue #545: the walk below prunes by directory modification date before
/// touching a single file, and its caller (`CostTracker.evidenceOfNewTranscripts`)
/// runs it off the main actor — the popover's own `.task` used to block on a
/// full ~10 GB / ~10k-file corpus walk because this ran synchronously inside
/// `MainActor.run`.
nonisolated enum CostScanFreshnessProbe {
    /// Whether any enabled provider's transcripts changed after `lastScanDate`.
    ///
    /// Resolves the same roots a real scan would (`ClaudeCostScanner`,
    /// `CodexCostScanner`, `GrokCostScanner`), so this is the production
    /// default `CostTracker.evidenceOfNewTranscripts` injects. Tests should
    /// inject their own closure rather than call this directly — it reads
    /// real account stores and home directories. Callers are expected to run
    /// this off the main actor (see `CostTracker.evidenceOfNewTranscripts`);
    /// it does no actor hopping itself so it stays trivially callable from a
    /// plain background queue.
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
            switch walk(root, since: date, fileNames: fileNames) {
            case .foundEvidence:
                return true
            case .noEvidence:
                continue
            case .incomplete:
                sawIncompleteWalk = true
            }
        }
        return sawIncompleteWalk ? nil : false
    }

    private enum WalkOutcome {
        /// A `.jsonl` modified at or after `date` was found — the caller can
        /// stop looking at every other root too.
        case foundEvidence
        /// The whole subtree was walked and nothing qualified.
        case noEvidence
        /// Part of the tree could not be walked (an unreadable directory, or
        /// a file whose modification date could not be read), so this root
        /// cannot vouch for `.noEvidence`.
        case incomplete
    }

    /// Walks `root` for the first `.jsonl` modified at or after `date`,
    /// pruning by directory modification date before stat-ing a single file
    /// (issue #545).
    ///
    /// A directory's own `contentModificationDate` only moves when an entry
    /// is added, removed, or renamed directly inside it — appending to an
    /// already-existing file never touches its parent's mtime, on APFS or
    /// any other filesystem this app runs on. So a directory untouched since
    /// `date` cannot have *gained* a transcript since `date`, and its whole
    /// subtree — however large — is skipped with `skipDescendants()` before
    /// a single file inside it is opened or stat'd. That is precisely the
    /// "worst when idle" case the bug report describes: nothing on disk is
    /// changing, so nothing needs a stat.
    ///
    /// What this does **not** catch: an existing, still-open transcript that
    /// keeps growing without any sibling ever being created nearby — its
    /// directory's mtime stays frozen even while the file's own mtime moves.
    /// Every provider this probe watches starts a fresh file per session
    /// (Claude nests one per subagent run too), so ongoing work keeps
    /// bumping directory mtimes on its own in the common case; a directory
    /// that goes fully quiet — no new files *and* no further writes to old
    /// ones — is exactly the corpus this pruning is for. This is the same
    /// class of tradeoff mtime-based change detection always carries (the
    /// "racy git" problem), not a correctness regression of #517: the
    /// decision this probe feeds still comes from real disk evidence, never
    /// from the calendar.
    private static func walk(_ root: URL, since date: Date, fileNames: Set<String>?) -> WalkOutcome {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        let keySet = Set(keys)
        let status = WalkStatus()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                status.markIncomplete()
                return true
            }
        ) else {
            return .incomplete
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                status.markIncomplete()
                continue
            }
            if values.isDirectory == true {
                // A stale mtime proves nothing was added, removed, or
                // renamed here since `date` — prune without descending. An
                // unreadable mtime is treated as "must check," not pruned.
                if let modified = values.contentModificationDate, modified < date {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            if let fileNames, !fileNames.contains(url.lastPathComponent) { continue }
            guard let modified = values.contentModificationDate else {
                status.markIncomplete()
                continue
            }
            if modified >= date { return .foundEvidence }
        }
        return status.isComplete ? .noEvidence : .incomplete
    }

    /// The enumerator's error handler outlives this call's stack frame, so
    /// the flag it sets cannot be a captured local — mirrors
    /// `CostScanCorpus`'s own `WalkStatus`, duplicated here rather than
    /// shared since that type is private to its file.
    private final class WalkStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var incomplete = false

        var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !incomplete
        }

        func markIncomplete() {
            lock.lock()
            incomplete = true
            lock.unlock()
        }
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
