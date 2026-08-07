import Foundation
import MeterBarShared
import os

/// One refresh's worth of scanning: the budget it spends, the per-file caches it
/// resumes from, and whether it managed to reach the end of the corpus.
///
/// A reference type on purpose. The scanners hand it down through per-file
/// helpers and mutate its caches as they go; a value type would mean either
/// `inout` on already-wide signatures or copying two dictionaries of ~10k
/// entries per file.
nonisolated final class CostScanSession: @unchecked Sendable {
    /// Start of the visible period window. Cached period totals are only valid
    /// for the cutoff they were tallied against, so this is part of every
    /// cache-hit decision.
    let cutoff: Date

    let budget: CostScanBudget

    private let store: CostScanCacheStore?
    private let lock = NSLock()
    private var claudeCache: CostScanFileCache<ClaudeFileTotals>
    private var codexCache: CostScanFileCache<CodexFileTotals>
    private var deferred = false

    init(
        cutoff: Date,
        options: CostScanBudgetOptions,
        store: CostScanCacheStore? = nil,
        token: CostScanCancellationToken = .never
    ) {
        self.cutoff = cutoff
        self.budget = CostScanBudget(options: options, token: token)
        self.store = store
        self.claudeCache = store?.loadClaude() ?? CostScanFileCache<ClaudeFileTotals>()
        self.codexCache = store?.loadCodex() ?? CostScanFileCache<CodexFileTotals>()
    }

    var claude: CostScanFileCache<ClaudeFileTotals> {
        lock.lock()
        defer { lock.unlock() }
        return claudeCache
    }

    var codex: CostScanFileCache<CodexFileTotals> {
        lock.lock()
        defer { lock.unlock() }
        return codexCache
    }

    var isCancelled: Bool { budget.isCancelled }

    /// `true` when this refresh walked the whole corpus. `false` means the
    /// budget ran out or the refresh was cancelled and some files were skipped
    /// entirely or read only partway — the caller should schedule another slice
    /// rather than treat the summary as final.
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !deferred
    }

    /// Records that at least one file was left unfinished.
    ///
    /// Deliberately *not* driven by "did we reach EOF": a transcript that is
    /// being appended to right now ends in a half-written line the scan
    /// legitimately withholds, and treating that as incomplete would keep the
    /// refresh loop spinning forever on a live session.
    func noteDeferred() {
        lock.lock()
        deferred = true
        lock.unlock()
    }

    func claudeRecord(for key: String) -> CostScanFileRecord<ClaudeFileTotals>? {
        lock.lock()
        defer { lock.unlock() }
        return claudeCache.records[key]
    }

    func setClaudeRecord(_ record: CostScanFileRecord<ClaudeFileTotals>, for key: String) {
        lock.lock()
        claudeCache.records[key] = record
        lock.unlock()
    }

    func codexRecord(for key: String) -> CostScanFileRecord<CodexFileTotals>? {
        lock.lock()
        defer { lock.unlock() }
        return codexCache.records[key]
    }

    func setCodexRecord(_ record: CostScanFileRecord<CodexFileTotals>, for key: String) {
        lock.lock()
        codexCache.records[key] = record
        lock.unlock()
    }

    /// Drops cache entries whose file no longer exists.
    ///
    /// Without this the cache grows forever: Claude Code and Codex delete old
    /// transcripts, and a stale entry would keep contributing its totals to
    /// every future summary even though the spend it describes is long gone.
    func retainClaude(keys: Set<String>) {
        lock.lock()
        claudeCache.records = claudeCache.records.filter { keys.contains($0.key) }
        lock.unlock()
    }

    func retainCodex(keys: Set<String>) {
        lock.lock()
        codexCache.records = codexCache.records.filter { keys.contains($0.key) }
        lock.unlock()
    }

    /// Writes both caches back, including after a cancelled slice — the whole
    /// point of committing on line boundaries is that partial progress is safe
    /// to keep.
    ///
    /// Deliberately not `@discardableResult`: a slice whose caches never reached
    /// disk made no *resumable* progress, and a caller that ignores that spends
    /// its remaining slices re-reading the same bytes.
    func persist() -> CostScanPersistOutcome {
        guard let store else { return .persisted }

        var outcome = CostScanPersistOutcome.persisted
        do {
            try store.saveClaude(claude)
        } catch {
            outcome = .failed
            AppLog.cost.error(
                "Failed to persist Claude scan progress: \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try store.saveCodex(codex)
        } catch {
            outcome = .failed
            AppLog.cost.error(
                "Failed to persist Codex scan progress: \(error.localizedDescription, privacy: .public)"
            )
        }
        return outcome
    }
}

/// Whether a slice's offsets are durable enough for the next one to resume from.
nonisolated enum CostScanPersistOutcome: Sendable, Equatable {
    /// Every cache this session owns is on disk — or there is no store, so there
    /// was never anything to lose.
    case persisted

    /// At least one cache could not be written. Whatever this slice read is
    /// still correct in memory, but it dies with the session: the store holds
    /// exactly what the previous slice left there.
    case failed
}
