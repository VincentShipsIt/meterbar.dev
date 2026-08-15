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

    /// Seven-day hourly boundary used to build `payload`'s hourly buckets.
    var hourlyCutoff: Date = .distantPast

    /// Whether the last pass read this file all the way to end of file.
    var isComplete: Bool

    var payload: Payload
}

/// Validates cached file identity and rebases its period payload when the
/// visible cutoff moves.
///
/// The validation order is correctness-critical: offsets are bounded before
/// any stamp comparison, complete files require an exact stamp, and incomplete
/// files may resume only when the same inode has grown or stayed the same size.
nonisolated enum CostScanResumption {
    static func resumableRecord<Payload>(
        existing: CostScanFileRecord<Payload>?,
        file: CostScanFile,
        cutoff: Date,
        rebase: (inout Payload, Date) -> Bool
    ) -> CostScanFileRecord<Payload>? {
        guard var record = existing else { return nil }
        guard record.offset <= UInt64(file.size) else { return nil }
        if record.isComplete, record.stamp.size == file.size {
            guard record.stamp.matches(file.stamp) else { return nil }
        } else {
            guard record.stamp.isSameFile(as: file.stamp),
                  file.size >= record.stamp.size else { return nil }
        }
        guard record.cutoff != cutoff else { return record }
        guard rebase(&record.payload, cutoff) else { return nil }
        record.cutoff = cutoff
        return record
    }
}

/// Provider payload behavior injected into ``CostScanResumption``.
nonisolated protocol CostScanPeriodRebasable: Codable, Sendable {
    mutating func rebasePeriod(to cutoff: Date) -> Bool
}

/// Every transcript's record, keyed by standardized path.
nonisolated struct CostScanFileCache<Payload: Codable & Sendable>: Codable, Sendable {
    /// Version 5 moves Claude's dedup keys out of the two top-level `periodKeys`
    /// / `lifetimeKeys` sets and into `eventKeys` on each window, where they
    /// survive EOF and can be checked across files. Version 4 added
    /// trailing-seven-day hourly accumulators. This private disposable cache
    /// intentionally invalidates the previous version so the upgrade's first
    /// background refresh re-reads source events instead of trusting offsets
    /// whose payload predates the change.
    static var currentSchemaVersion: Int { 5 }

    var schemaVersion = CostScanFileCache.currentSchemaVersion
    var parserVersion = CostScanValues.costCacheParserVersion
    var timeZoneIdentifier = TimeZone.current.identifier
    var records: [String: CostScanFileRecord<Payload>] = [:]
}

/// Reads and writes the per-file scan caches — one artifact per corpus.
///
/// Deliberately separate files from `cost-summary-v2.json`: that envelope is a
/// published artifact (`meterbar cost` reads it) with its own schema version and
/// its own migration story, while these are a private, disposable read-through
/// cache. Losing them costs one slow refresh, not a wrong number.
///
/// One artifact per corpus, never a shared one: the payload types differ, and a
/// corpus added later must not invalidate the caches the existing ones already
/// filled.
nonisolated struct CostScanCacheStore: Sendable {
    static let maximumArtifactBytes = 64 * 1024 * 1024
    static var claudeFileName: String {
        "cost-scan-claude-v\(CostScanFileCache<ClaudeFileTotals>.currentSchemaVersion).json"
    }
    static var codexFileName: String {
        "cost-scan-codex-v\(CostScanFileCache<CodexFileTotals>.currentSchemaVersion).json"
    }
    static var grokFileName: String {
        "cost-scan-grok-v\(CostScanFileCache<GrokFileTotals>.currentSchemaVersion).json"
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

    func loadGrok() -> CostScanFileCache<GrokFileTotals> {
        Self.loadGrok(from: directory.appendingPathComponent(Self.grokFileName))
    }

    func saveClaude(_ cache: CostScanFileCache<ClaudeFileTotals>) throws {
        try Self.saveClaude(cache, to: directory.appendingPathComponent(Self.claudeFileName))
    }

    func saveCodex(_ cache: CostScanFileCache<CodexFileTotals>) throws {
        try Self.saveCodex(cache, to: directory.appendingPathComponent(Self.codexFileName))
    }

    func saveGrok(_ cache: CostScanFileCache<GrokFileTotals>) throws {
        try Self.saveGrok(cache, to: directory.appendingPathComponent(Self.grokFileName))
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

    static func loadGrok(
        from url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) -> CostScanFileCache<GrokFileTotals> {
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

    static func saveGrok(
        _ cache: CostScanFileCache<GrokFileTotals>,
        to url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) throws {
        try Self.save(cache, to: url, maximumBytes: maximumBytes)
    }

    /// Every payload rolls usage up in `[Date: TokenAccumulator]` dictionaries,
    /// and a mismatched date strategy across them would not throw — every
    /// strategy but `.iso8601` writes a bare number, so the decode succeeds and
    /// lands each daily row in a bucket decades from the right one. Pinned
    /// explicitly rather than left to independently-defaulted instances that
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

    /// Writes one cache through, or throws describing which stage failed.
    ///
    /// Each stage is mapped to its own case rather than letting the underlying
    /// error escape: the caller logs this and nothing else, so "the encoder
    /// refused a value", "the directory could not be prepared", and "the bytes
    /// never landed" have to be distinguishable from the log line alone. The
    /// atomic-replace behaviour is unchanged — a failure at any stage leaves the
    /// previous artifact exactly as it was.
    private static func save<Payload>(
        _ cache: CostScanFileCache<Payload>,
        to url: URL,
        maximumBytes: Int
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(cache)
        } catch {
            throw CostScanCacheStoreError.encodingFailed(reason: CostScanCacheStoreError.reason(for: error))
        }
        guard data.count <= maximumBytes else {
            throw CostScanCacheStoreError.artifactTooLarge(data.count)
        }
        do {
            try SecureFileWriter.ensurePrivateDirectory(url.deletingLastPathComponent())
        } catch {
            throw CostScanCacheStoreError.directoryUnavailable(reason: CostScanCacheStoreError.reason(for: error))
        }
        do {
            try SecureFileWriter.write(data, to: url)
        } catch {
            throw CostScanCacheStoreError.writeFailed(reason: CostScanCacheStoreError.reason(for: error))
        }
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

/// Why a cache could not be written. One case per stage of ``save``, because a
/// scan that stops resuming is diagnosed from this line and no other.
nonisolated enum CostScanCacheStoreError: LocalizedError {
    case artifactTooLarge(Int)
    case encodingFailed(reason: String)
    case directoryUnavailable(reason: String)
    case writeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .artifactTooLarge(bytes):
            "Cost scan cache is too large to persist (\(bytes) bytes)"
        case let .encodingFailed(reason):
            "Could not encode the cost scan cache: \(reason)"
        case let .directoryUnavailable(reason):
            "Could not prepare the cost scan cache directory: \(reason)"
        case let .writeFailed(reason):
            "Could not write the cost scan cache: \(reason)"
        }
    }

    /// Describes `error` without the file paths its own description carries.
    ///
    /// These reasons are logged at `privacy: .public`, and every path involved
    /// sits under the user's home directory. An errno, or failing that a domain
    /// and code, says what to do about it; the path says who the user is.
    /// Encoder failures matter here too — the cache is keyed by transcript path,
    /// so `EncodingError`'s own description would name one.
    static func reason(for error: Error) -> String {
        SecureFileWriterError.logDescription(for: error)
    }
}

/// One Claude transcript's tally.
///
/// The dedup state a resumed read needs lives on the windows themselves, as
/// `ClaudeSessionTotals.eventKeys` — same shape Codex and Grok get from
/// `CostScanWindowContext.eventKeys`, and the reason those keys can also answer
/// "have I already counted this event from a *different* file?".
nonisolated struct ClaudeFileTotals: Codable, Sendable {
    var period = ClaudeSessionTotals()
    var lifetime = ClaudeSessionTotals()
}

/// One Codex rollout's tally, plus the attribution state carried across slices.
nonisolated struct CodexFileTotals: Codable, Sendable {
    var period: CostScanWindowContext
    var lifetime: CostScanWindowContext

    /// `turn_context` / `session_meta` attribution seen so far. A rollout
    /// declares its model once and its originator once, usually in the first few
    /// hundred bytes, so a slice that starts past them would attribute every
    /// remaining event to "unknown" without this.
    var rollout = CodexRolloutContext()

    init(cutoff: Date) {
        period = CostScanWindowContext(earliestDate: Date(), latestDate: cutoff)
        lifetime = CostScanWindowContext(earliestDate: Date(), latestDate: .distantPast)
    }
}

/// One Grok `updates.jsonl` tally.
///
/// No `rollout` analog: a Grok turn names its own model inside `modelUsage`, and
/// the project comes from the session directory's own name, so a slice that
/// starts mid-file still attributes every record it reads.
nonisolated struct GrokFileTotals: Codable, Sendable {
    var period: CostScanWindowContext
    var lifetime: CostScanWindowContext

    init(cutoff: Date) {
        period = CostScanWindowContext(earliestDate: Date(), latestDate: cutoff)
        lifetime = CostScanWindowContext(earliestDate: Date(), latestDate: .distantPast)
    }
}

nonisolated extension ClaudeFileTotals: CostScanPeriodRebasable {
    mutating func rebasePeriod(to cutoff: Date) -> Bool {
        // The period window slides every day; lifetime totals never expire. So
        // the only question is whether the cached period tally can be rebased
        // without re-reading the file.
        if (lifetime.latest ?? .distantPast) < cutoff {
            // Every event predates the new window. Its keys go with it: they
            // describe what the period tally counted, and it now counts nothing.
            period = ClaudeSessionTotals()
        } else if (lifetime.earliest ?? .distantFuture) >= cutoff {
            // Every event falls inside it.
            period = lifetime
        } else {
            // The file straddles the cutoff and only its individual events know
            // where. Re-read it — but only files that actually straddle pay.
            return false
        }
        return true
    }
}

/// The identical period/lifetime shape shared by Codex and Grok payloads.
nonisolated protocol CostScanWindowPeriodRebasable: CostScanPeriodRebasable {
    var period: CostScanWindowContext { get set }
    var lifetime: CostScanWindowContext { get }
}

nonisolated extension CostScanWindowPeriodRebasable {
    mutating func rebasePeriod(to cutoff: Date) -> Bool {
        if lifetime.eventKeys.isEmpty || lifetime.latestDate < cutoff {
            // Every event predates the new window.
            period = CostScanWindowContext(
                earliestDate: Date(),
                latestDate: cutoff
            )
        } else if lifetime.earliestDate >= cutoff {
            // Every event falls inside it.
            period = lifetime
        } else {
            // The file straddles the cutoff. Only its individual events or
            // records know where, so only files that straddle pay to re-read.
            return false
        }
        return true
    }
}

nonisolated extension CodexFileTotals: CostScanWindowPeriodRebasable {}
nonisolated extension GrokFileTotals: CostScanWindowPeriodRebasable {}
