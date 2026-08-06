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

    /// File identity when `offset` was written. Size alone cannot distinguish
    /// an append from an atomic replacement at the same path.
    var stamp: CostScanFileStamp

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
    /// Version 3 adds producer/time-zone identity and full per-file stamps.
    static var currentSchemaVersion: Int { 3 }

    var schemaVersion = CostScanFileCache.currentSchemaVersion
    var parserVersion = CostScanValues.costCacheParserVersion
    var timeZoneIdentifier = TimeZone.current.identifier
    var records: [String: CostScanFileRecord<Payload>] = [:]
}

/// Reads and writes the two per-file scan caches.
///
/// Deliberately separate files from `cost-summary-v2.json`: that envelope is a
/// published artifact (`meterbar cost` reads it) with its own schema version and
/// its own migration story, while these are a private, disposable read-through
/// cache. Losing them costs one slow refresh, not a wrong number.
nonisolated struct CostScanCacheStore: Sendable {
    static let maximumArtifactBytes = 64 * 1024 * 1024
    static var claudeFileName: String {
        "cost-scan-claude-v\(CostScanFileCache<ClaudeFileTotals>.currentSchemaVersion).json"
    }
    static var codexFileName: String {
        "cost-scan-codex-v\(CostScanFileCache<CodexFileTotals>.currentSchemaVersion).json"
    }

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
        Self.loadClaude(from: directory.appendingPathComponent(Self.claudeFileName))
    }

    func loadCodex() -> CostScanFileCache<CodexFileTotals> {
        Self.loadCodex(from: directory.appendingPathComponent(Self.codexFileName))
    }

    func saveClaude(_ cache: CostScanFileCache<ClaudeFileTotals>) throws {
        try Self.saveClaude(cache, to: directory.appendingPathComponent(Self.claudeFileName))
    }

    func saveCodex(_ cache: CostScanFileCache<CodexFileTotals>) throws {
        try Self.saveCodex(cache, to: directory.appendingPathComponent(Self.codexFileName))
    }

    static func loadClaude(
        from url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) -> CostScanFileCache<ClaudeFileTotals> {
        Self.load(from: url, maximumBytes: maximumBytes)
    }

    static func loadCodex(
        from url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) -> CostScanFileCache<CodexFileTotals> {
        Self.load(from: url, maximumBytes: maximumBytes)
    }

    static func saveClaude(
        _ cache: CostScanFileCache<ClaudeFileTotals>,
        to url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) throws {
        try Self.save(cache, to: url, maximumBytes: maximumBytes)
    }

    static func saveCodex(
        _ cache: CostScanFileCache<CodexFileTotals>,
        to url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) throws {
        try Self.save(cache, to: url, maximumBytes: maximumBytes)
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

    private static func load<Payload>(
        from url: URL,
        maximumBytes: Int
    ) -> CostScanFileCache<Payload> {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let cache = try? decoder.decode(CostScanFileCache<Payload>.self, from: data),
              cache.schemaVersion == CostScanFileCache<Payload>.currentSchemaVersion,
              cache.parserVersion == CostScanValues.costCacheParserVersion,
              cache.timeZoneIdentifier == TimeZone.current.identifier else {
            // A cache from a future or unreadable build is dropped, not
            // migrated: a full re-scan is slow, but a mis-decoded offset would
            // silently under-count forever.
            return CostScanFileCache<Payload>()
        }
        return cache
    }

    private static func save<Payload>(
        _ cache: CostScanFileCache<Payload>,
        to url: URL,
        maximumBytes: Int
    ) throws {
        let data = try encoder.encode(cache)
        guard data.count <= maximumBytes else {
            throw CostScanCacheStoreError.artifactTooLarge(data.count)
        }
        try SecureFileWriter.ensurePrivateDirectory(url.deletingLastPathComponent())
        try SecureFileWriter.write(data, to: url)
        Self.removeSupersededFiles(for: url)
    }

    private static func removeSupersededFiles(for currentURL: URL) {
        let directory = currentURL.deletingLastPathComponent()
        let stem = currentURL.lastPathComponent
            .split(separator: "-v", maxSplits: 1)
            .first
            .map(String.init) ?? currentURL.deletingPathExtension().lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let currentPath = currentURL.standardizedFileURL.path
        for file in files where file.standardizedFileURL.path != currentPath
            && file.lastPathComponent.hasPrefix("\(stem)-v")
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

nonisolated enum CostScanCacheStoreError: LocalizedError {
    case artifactTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case let .artifactTooLarge(bytes):
            "Cost scan cache is too large to persist (\(bytes) bytes)"
        }
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
