import Foundation

/// What one transcript contributed, and where to pick its reading back up.
///
/// The byte offset lives on the same entry as the totals on purpose. Two stores
/// — "offsets here, totals there" — can disagree after a crash or a partial
/// write, and the failure is silent: the scan seeks past bytes whose totals were
/// never persisted, so that spend disappears from the summary until the file is
/// rewritten. One entry, written once, cannot drift.
nonisolated struct CostScanFileRecord<Payload: Codable & Sendable>: Codable, Sendable {
    /// Byte offset one past the last *complete* line folded into `payload`.
    var offset: UInt64

    /// The file's size when `offset` was written. A file that has since shrunk
    /// was rotated or replaced, so the cached totals describe bytes that no
    /// longer exist — the entry is discarded rather than resumed.
    var size: Int

    /// The period cutoff `payload`'s period window was computed against. The
    /// 30-day window slides every day, so a record written yesterday describes
    /// the wrong period today and has to be rebased (or re-read) before use.
    var cutoff: Date

    /// Whether the last pass read this file all the way to end of file.
    var isComplete: Bool

    var payload: Payload
}

/// Every transcript's record, keyed by standardized path.
nonisolated struct CostScanFileCache<Payload: Codable & Sendable>: Codable, Sendable {
    /// Bumped to 2 when the date strategy was pinned to `.secondsSince1970`: a
    /// v1 file's dates were written against `.deferredToDate`'s 2001 epoch, and
    /// decoding those numbers as Unix seconds succeeds while landing every daily
    /// row 31 years early. Dropping the file costs one slow refresh; reading it
    /// would be silently wrong.
    static var currentSchemaVersion: Int { 2 }

    var schemaVersion = CostScanFileCache.currentSchemaVersion
    var records: [String: CostScanFileRecord<Payload>] = [:]
}

/// Reads and writes the two per-file scan caches.
///
/// Deliberately separate files from `cost-summary-v2.json`: that envelope is a
/// published artifact (`meterbar cost` reads it) with its own schema version and
/// its own migration story, while these are a private, disposable read-through
/// cache. Losing them costs one slow refresh, not a wrong number.
nonisolated struct CostScanCacheStore: Sendable {
    /// The `v1` in the file names is the *path* generation, not the schema —
    /// `schemaVersion` inside the file is what gates a read. Bumping the name
    /// too would strand the old file on disk forever with nothing to delete it.
    static let claudeFileName = "cost-scan-claude-v1.json"
    static let codexFileName = "cost-scan-codex-v1.json"

    let directory: URL

    /// `~/Library/Application Support/MeterBar`, alongside the summary cache.
    static var applicationSupport: CostScanCacheStore? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return CostScanCacheStore(
            directory: support.appendingPathComponent("MeterBar", isDirectory: true)
        )
    }

    func loadClaude() -> CostScanFileCache<ClaudeFileTotals> {
        Self.load(from: directory.appendingPathComponent(Self.claudeFileName))
    }

    func loadCodex() -> CostScanFileCache<CodexFileTotals> {
        Self.load(from: directory.appendingPathComponent(Self.codexFileName))
    }

    func saveClaude(_ cache: CostScanFileCache<ClaudeFileTotals>) throws {
        try Self.save(cache, to: directory.appendingPathComponent(Self.claudeFileName))
    }

    func saveCodex(_ cache: CostScanFileCache<CodexFileTotals>) throws {
        try Self.save(cache, to: directory.appendingPathComponent(Self.codexFileName))
    }

    /// Both payloads roll usage up in `[Date: TokenAccumulator]` dictionaries,
    /// and a mismatched date strategy across these two would not throw — every
    /// strategy but `.iso8601` writes a bare number, so the decode succeeds and
    /// lands each daily row in a bucket decades from the right one. Pinned
    /// explicitly rather than left to two independently-defaulted instances that
    /// only happen to agree today.
    private static var encoder: JSONEncoder {
        // Not `.prettyPrinted`: ~10k entries, and this file is machine-only.
        // Pretty printing roughly doubles it for nobody's benefit.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func load<Payload>(from url: URL) -> CostScanFileCache<Payload> {
        guard let data = try? Data(contentsOf: url),
              let cache = try? decoder.decode(CostScanFileCache<Payload>.self, from: data),
              cache.schemaVersion == CostScanFileCache<Payload>.currentSchemaVersion else {
            // A cache from a future or unreadable build is dropped, not
            // migrated: a full re-scan is slow, but a mis-decoded offset would
            // silently under-count forever.
            return CostScanFileCache<Payload>()
        }
        return cache
    }

    private static func save<Payload>(_ cache: CostScanFileCache<Payload>, to url: URL) throws {
        let data = try encoder.encode(cache)
        try SecureFileWriter.ensurePrivateDirectory(url.deletingLastPathComponent())
        try SecureFileWriter.write(data, to: url)
    }
}

/// One Claude transcript's tally, plus the dedup state a resumed read needs.
nonisolated struct ClaudeFileTotals: Codable, Sendable {
    var period = ClaudeSessionTotals()
    var lifetime = ClaudeSessionTotals()

    /// `messageID:requestID` keys already folded into each window.
    ///
    /// Kept only while the file is still being read. Within a single pass the
    /// scanner keeps the *last* event for a duplicate key; across a resume
    /// boundary the earlier slice is already tallied, so a duplicate that
    /// arrives in a later slice is dropped instead — first-wins. The two differ
    /// only when a transcript repeats a key with different token counts, which
    /// Claude Code does not do; both are one-copy-counted, which is the property
    /// that matters.
    var periodKeys: Set<String> = []
    var lifetimeKeys: Set<String> = []
}

/// One Codex rollout's tally, plus the attribution state carried across slices.
nonisolated struct CodexFileTotals: Codable, Sendable {
    var period: CodexScanContext
    var lifetime: CodexScanContext

    /// `turn_context` / `session_meta` attribution seen so far. A rollout
    /// declares its model once and its originator once, usually in the first few
    /// hundred bytes, so a slice that starts past them would attribute every
    /// remaining event to "unknown" without this.
    var rollout = CodexRolloutContext()

    init(cutoff: Date) {
        period = CodexScanContext(earliestDate: Date(), latestDate: cutoff)
        lifetime = CodexScanContext(earliestDate: Date(), latestDate: .distantPast)
    }
}
