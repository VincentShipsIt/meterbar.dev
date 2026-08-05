import Foundation

/// One refresh's view of the incremental scan cache.
///
/// Transcripts and rollouts are append-only and mostly frozen: on a developer
/// machine the archived corpus is gigabytes that produce byte-identical totals
/// on every scan. This holds the previous run's parse results, hands them back
/// when a file's stamp still matches, and collects what the current run saw so
/// the next run can start from it.
///
/// `next` — not `previous` — is what gets written back, which is what makes a
/// deleted file disappear from the cache: a file nobody visited is a file
/// nobody records.
nonisolated final class CostScanCache: @unchecked Sendable {
    /// Roughly 64 MB of JSON at ~8 printed bytes per value. Large enough that a
    /// ten-gigabyte corpus fits comfortably; small enough that a pathological
    /// one cannot grow the cache without bound.
    static let defaultMaximumValues = 8_000_000
    static let defaultMaximumEntries = 50_000

    /// `NSLock` rather than an actor: the scanners are `nonisolated` static
    /// functions called from a background task, and per-file parsing is being
    /// parallelized separately. A lock keeps this safe for concurrent lookups
    /// without forcing the callers to become async.
    private let lock = NSLock()

    private let previousClaude: [String: ClaudeCacheEntry]
    private let previousCodex: [String: CodexCacheEntry]
    private let timeZoneIdentifier: String

    private var nextClaude: [String: ClaudeCacheEntry] = [:]
    private var nextCodex: [String: CodexCacheEntry] = [:]
    private var hitCount = 0
    private var missCount = 0

    convenience init() {
        self.init(
            previous: CostScanCacheFile(
                timeZoneIdentifier: TimeZone.current.identifier,
                claude: [],
                codex: []
            )
        )
    }

    init(previous: CostScanCacheFile) {
        let identifier = TimeZone.current.identifier
        timeZoneIdentifier = identifier
        // Claude digests are pre-bucketed into local days; Codex records keep
        // raw timestamps and re-bucket on replay. So a time-zone change only
        // invalidates the Claude half.
        previousClaude = previous.timeZoneIdentifier == identifier
            ? Dictionary(previous.claude.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            : [:]
        previousCodex = Dictionary(previous.codex.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Never throws and never returns `nil`: an unreadable, corrupt,
    /// version-mismatched, or oversized file is indistinguishable from a cold
    /// start.
    static func load(
        from url: URL,
        maximumBytes: Int = CostScanCacheStore.maximumArtifactBytes
    ) -> CostScanCache {
        guard let file = CostScanCacheStore.load(from: url, maximumBytes: maximumBytes) else {
            return CostScanCache()
        }
        return CostScanCache(previous: file)
    }

    var hits: Int { lock.withLock { hitCount } }
    var misses: Int { lock.withLock { missCount } }

    // MARK: - Lookups

    /// Returns a usable entry without counting it. The caller still has to
    /// reconstruct totals from the digest, and a digest that fails to
    /// reconstruct is a miss — so the hit is recorded by `noteHit` once the
    /// entry has actually been used.
    func claudeEntry(forPath path: String, stamp: CostScanFileStamp) -> ClaudeCacheEntry? {
        lock.withLock {
            guard let entry = previousClaude[path], entry.stamp.matches(stamp) else { return nil }
            return entry
        }
    }

    func codexEntry(forPath path: String, stamp: CostScanFileStamp) -> CodexCacheEntry? {
        lock.withLock {
            guard let entry = previousCodex[path], entry.stamp.matches(stamp) else { return nil }
            return entry
        }
    }

    func noteHit(carrying entry: ClaudeCacheEntry) {
        lock.withLock {
            hitCount += 1
            nextClaude[entry.path] = entry
        }
    }

    func noteHit(carrying entry: CodexCacheEntry) {
        lock.withLock {
            hitCount += 1
            nextCodex[entry.path] = entry
        }
    }

    /// Recorded by the scanner immediately before it parses, so a file that is
    /// parsed but deliberately *not* cached still counts as a miss.
    func noteMiss() {
        lock.withLock { missCount += 1 }
    }

    // MARK: - Stores

    func store(_ entry: ClaudeCacheEntry) {
        lock.withLock { nextClaude[entry.path] = entry }
    }

    func store(_ entry: CodexCacheEntry) {
        lock.withLock { nextCodex[entry.path] = entry }
    }

    /// Keeps a provider's entries alive across a refresh that never looked at
    /// it. Without this, turning Claude Code or Codex off in Settings would
    /// silently discard gigabytes of valid cache and make re-enabling it a full
    /// re-parse.
    func carryForwardClaudeEntries() {
        lock.withLock {
            for (path, entry) in previousClaude where nextClaude[path] == nil {
                nextClaude[path] = entry
            }
        }
    }

    func carryForwardCodexEntries() {
        lock.withLock {
            for (path, entry) in previousCodex where nextCodex[path] == nil {
                nextCodex[path] = entry
            }
        }
    }

    // MARK: - Persistence

    func snapshot() -> CostScanCacheFile {
        snapshot(maximumValues: Self.defaultMaximumValues, maximumEntries: Self.defaultMaximumEntries)
    }

    /// Everything this scan observed, trimmed to fit the budget.
    ///
    /// Eviction keeps the entries with the highest savings density — bytes of
    /// transcript avoided per value stored. A 40 MB rollout that reduces to a
    /// handful of buckets is worth far more shelf space than a 4 KB one, so when
    /// the cache has to shrink, the biggest files are the ones worth remembering.
    func snapshot(maximumValues: Int, maximumEntries: Int) -> CostScanCacheFile {
        lock.withLock {
            var candidates = nextClaude.values.map {
                Candidate(path: $0.path, isClaude: true, size: $0.stamp.size, values: $0.digest.valueCount)
            }
            candidates.append(
                contentsOf: nextCodex.values.map {
                    Candidate(path: $0.path, isClaude: false, size: $0.stamp.size, values: $0.digest.valueCount)
                }
            )

            var claude: [ClaudeCacheEntry] = []
            var codex: [CodexCacheEntry] = []
            var usedValues = 0

            for candidate in candidates.sorted(by: Self.isMoreValuable) {
                guard claude.count + codex.count < maximumEntries else { break }
                guard usedValues + candidate.values <= maximumValues else { continue }
                usedValues += candidate.values
                if candidate.isClaude {
                    if let entry = nextClaude[candidate.path] { claude.append(entry) }
                } else if let entry = nextCodex[candidate.path] {
                    codex.append(entry)
                }
            }

            return CostScanCacheFile(timeZoneIdentifier: timeZoneIdentifier, claude: claude, codex: codex)
        }
    }

    func persist(to url: URL) {
        do {
            try CostScanCacheStore.save(snapshot(), to: url)
        } catch {
            // A cache that cannot be written costs speed, never correctness —
            // the next scan simply starts cold.
            AppLog.storage.warning("Failed to persist cost scan cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct Candidate {
        let path: String
        let isClaude: Bool
        let size: Int64
        let values: Int

        var density: Double { Double(size) / Double(max(1, values)) }
    }

    /// Density first, then raw size, then path — the last two only to keep the
    /// eviction order deterministic across runs.
    private static func isMoreValuable(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.density != rhs.density { return lhs.density > rhs.density }
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        return lhs.path < rhs.path
    }
}
