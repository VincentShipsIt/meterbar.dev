import Foundation
import MeterBarShared
import os

/// Type-safe route to one provider's cache inside a scan session.
nonisolated struct CostScanCacheKey<Payload: Codable & Sendable> {
    fileprivate let provider: CostScanProvider
    fileprivate let cache: ReferenceWritableKeyPath<CostScanSession, CostScanFileCache<Payload>>
    fileprivate let save: (CostScanCacheStore, CostScanFileCache<Payload>) throws -> Void
}

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
    /// Start of the seven-calendar-day hour buckets retained by this refresh.
    let hourlyCutoff: Date

    let budget: CostScanBudget

    private let store: CostScanCacheStore?
    private let lock = NSLock()
    fileprivate var claudeCache: CostScanFileCache<ClaudeFileTotals>
    fileprivate var codexCache: CostScanFileCache<CodexFileTotals>
    fileprivate var grokCache: CostScanFileCache<GrokFileTotals>
    private var dirtyProviders: Set<CostScanProvider> = []
    private var deferred: Set<CostScanProvider> = []

    init(
        cutoff: Date,
        hourlyCutoff: Date = .distantPast,
        options: CostScanBudgetOptions,
        store: CostScanCacheStore? = nil,
        token: CostScanCancellationToken = .never
    ) {
        self.cutoff = cutoff
        self.hourlyCutoff = hourlyCutoff
        self.budget = CostScanBudget(options: options, token: token)
        self.store = store
        self.claudeCache = store?.loadClaude() ?? CostScanFileCache<ClaudeFileTotals>()
        self.codexCache = store?.loadCodex() ?? CostScanFileCache<CodexFileTotals>()
        self.grokCache = store?.loadGrok() ?? CostScanFileCache<GrokFileTotals>()
    }

    var claude: CostScanFileCache<ClaudeFileTotals> {
        cache(for: .claude)
    }

    var codex: CostScanFileCache<CodexFileTotals> {
        cache(for: .codex)
    }

    var grok: CostScanFileCache<GrokFileTotals> {
        cache(for: .grok)
    }

    func cache<Payload>(for provider: CostScanCacheKey<Payload>) -> CostScanFileCache<Payload> {
        lock.lock()
        defer { lock.unlock() }
        return self[keyPath: provider.cache]
    }

    var isCancelled: Bool { budget.isCancelled }

    /// `true` when this refresh walked the whole corpus. `false` means the
    /// budget ran out or the refresh was cancelled and some files were skipped
    /// entirely or read only partway — the caller should schedule another slice
    /// rather than treat the summary as final.
    var isComplete: Bool { deferredProviders.isEmpty }

    /// Which corpora were left unfinished.
    ///
    /// Tracked per provider rather than as one flag because the slice loop's
    /// stop condition pairs each of these with that provider's own persist
    /// outcome: a provider that still has work but cannot write its offsets is
    /// the one case where another slice buys nothing.
    var deferredProviders: Set<CostScanProvider> {
        lock.lock()
        defer { lock.unlock() }
        return deferred
    }

    /// Records that at least one of `provider`'s files was left unfinished.
    ///
    /// Deliberately *not* driven by "did we reach EOF": a transcript that is
    /// being appended to right now ends in a half-written line the scan
    /// legitimately withholds, and treating that as incomplete would keep the
    /// refresh loop spinning forever on a live session.
    func noteDeferred(_ provider: CostScanProvider) {
        lock.lock()
        deferred.insert(provider)
        lock.unlock()
    }

    func record<Payload>(
        for key: String,
        provider: CostScanCacheKey<Payload>
    ) -> CostScanFileRecord<Payload>? {
        lock.lock()
        defer { lock.unlock() }
        return self[keyPath: provider.cache].records[key]
    }

    func setRecord<Payload>(
        _ record: CostScanFileRecord<Payload>,
        for key: String,
        provider: CostScanCacheKey<Payload>
    ) {
        lock.lock()
        self[keyPath: provider.cache].records[key] = record
        dirtyProviders.insert(provider.provider)
        lock.unlock()
    }

    // Scanners route through the generic pair above. These named seams stay for
    // tests, which build a session's starting state directly and read better
    // naming the provider than spelling out the payload type at every call.
    func setClaudeRecord(_ record: CostScanFileRecord<ClaudeFileTotals>, for key: String) {
        setRecord(record, for: key, provider: .claude)
    }

    func setCodexRecord(_ record: CostScanFileRecord<CodexFileTotals>, for key: String) {
        setRecord(record, for: key, provider: .codex)
    }

    func setGrokRecord(_ record: CostScanFileRecord<GrokFileTotals>, for key: String) {
        setRecord(record, for: key, provider: .grok)
    }

    /// Drops cache entries whose file no longer exists.
    ///
    /// Without this the cache grows forever: Claude Code and Codex delete old
    /// transcripts, and a stale entry would keep contributing its totals to
    /// every future summary even though the spend it describes is long gone.
    func retain<Payload>(keys: Set<String>, provider: CostScanCacheKey<Payload>) {
        lock.lock()
        let previousCount = self[keyPath: provider.cache].records.count
        self[keyPath: provider.cache].records = self[keyPath: provider.cache].records.filter {
            keys.contains($0.key)
        }
        if self[keyPath: provider.cache].records.count != previousCount {
            dirtyProviders.insert(provider.provider)
        }
        lock.unlock()
    }

    func retainClaude(keys: Set<String>) {
        retain(keys: keys, provider: .claude)
    }

    func retainCodex(keys: Set<String>) {
        retain(keys: keys, provider: .codex)
    }

    /// Writes caches with pending changes, including after a cancelled slice —
    /// the whole point of committing on line boundaries is that partial
    /// progress is safe to keep.
    ///
    /// Deliberately not `@discardableResult`: a slice whose caches never reached
    /// disk made no *resumable* progress, and a caller that ignores that spends
    /// its remaining slices re-reading the same bytes.
    func persist() -> CostScanPersistReport {
        // No store is not the same as nothing to save. `CostScanCacheStore
        // .applicationSupport` is optional, and every slice builds a fresh
        // session from it — so a session without one starts from an empty cache,
        // re-reads the corpus from offset 0, and defers in the same place. Say
        // so, or the slice loop keeps calling that forward progress.
        guard let store else { return .unavailable }

        return CostScanPersistReport(
            claude: persist(provider: .claude, to: store),
            codex: persist(provider: .codex, to: store),
            grok: persist(provider: .grok, to: store)
        )
    }

    private func persist<Payload>(
        provider: CostScanCacheKey<Payload>,
        to store: CostScanCacheStore
    ) -> CostScanPersistOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard dirtyProviders.contains(provider.provider) else { return .persisted }
        let outcome = Self.write(provider.provider.logName) {
            try provider.save(store, self[keyPath: provider.cache])
        }
        if outcome == .persisted { dirtyProviders.remove(provider.provider) }
        return outcome
    }

    private static func write(_ provider: String, _ save: () throws -> Void) -> CostScanPersistOutcome {
        do {
            try save()
            return .persisted
        } catch {
            AppLog.cost.error(
                """
                Failed to persist \(provider, privacy: .public) scan progress: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .failed
        }
    }
}

nonisolated extension CostScanCacheKey where Payload == ClaudeFileTotals {
    static var claude: Self {
        Self(
            provider: .claude,
            cache: \CostScanSession.claudeCache,
            save: { store, cache in try store.saveClaude(cache) }
        )
    }
}

nonisolated extension CostScanCacheKey where Payload == CodexFileTotals {
    static var codex: Self {
        Self(
            provider: .codex,
            cache: \CostScanSession.codexCache,
            save: { store, cache in try store.saveCodex(cache) }
        )
    }
}

nonisolated extension CostScanCacheKey where Payload == GrokFileTotals {
    static var grok: Self {
        Self(
            provider: .grok,
            cache: \CostScanSession.grokCache,
            save: { store, cache in try store.saveGrok(cache) }
        )
    }
}

/// The corpora a refresh reads. They have separate caches, separate budgets
/// to run out of, and separate ways to fail a write, so every "did this make
/// resumable progress" answer is scoped to one of them.
nonisolated enum CostScanProvider: Sendable, Hashable, CaseIterable {
    case claude
    case codex
    case grok

    /// The user-facing service this corpus bills against, so callers can gate a
    /// scan on `ProviderVisibilityStore` without a second parallel mapping.
    var service: ServiceType {
        switch self {
        case .claude: .claudeCode
        case .codex: .codexCli
        case .grok: .grok
        }
    }

    /// Name used in log lines. A stored mapping rather than a ternary at each
    /// call site — the two-way ternary this replaced silently labelled every
    /// non-Claude provider "Codex".
    var logName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }
}

/// Whether a slice's offsets are durable enough for the next one to resume from.
///
/// Only `persisted` earns another slice. The two failure shapes are kept apart
/// because they need different log lines — one is a disk error worth reporting,
/// the other is a machine whose Application Support directory never resolved.
nonisolated enum CostScanPersistOutcome: Sendable, Equatable {
    /// This provider's cache is on disk.
    case persisted

    /// The cache could not be written. Whatever this slice read is still correct
    /// in memory, but it dies with the session: the store holds exactly what the
    /// previous slice left there.
    case failed

    /// There is no store to write to, so nothing this slice read can outlive
    /// it. Correct for the summary on screen, useless to the next slice.
    case unavailable
}

/// One slice's persist result, per provider.
///
/// Kept apart rather than reduced to a single worst-case verdict: the caches are
/// separate artifacts, and a shared verdict would let a permanently blocked
/// Claude write cancel Codex's scan while Codex is still resuming cleanly.
nonisolated struct CostScanPersistReport: Sendable, Equatable {
    /// Every cache reached disk.
    static let persisted = CostScanPersistReport(claude: .persisted, codex: .persisted, grok: .persisted)

    /// There was no store, so no cache could outlive the slice.
    static let unavailable = CostScanPersistReport(
        claude: .unavailable,
        codex: .unavailable,
        grok: .unavailable
    )

    let claude: CostScanPersistOutcome
    let codex: CostScanPersistOutcome
    let grok: CostScanPersistOutcome

    func outcome(for provider: CostScanProvider) -> CostScanPersistOutcome {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .grok: grok
        }
    }
}
