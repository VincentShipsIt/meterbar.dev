import Foundation

/// Reads and writes the poll-and-accumulate ledger — one artifact, separate from
/// every scanner cache.
///
/// Its own file on purpose. The `cost-scan-*` caches are a disposable
/// read-through cache over logs that still exist on disk: losing one costs a
/// slow re-scan and no data. This ledger is the *only* copy of Cursor's and
/// OpenRouter's history — neither provider will re-serve a day once it has
/// passed — so it must not be invalidated by a parser-version bump or a schema
/// change that has nothing to do with it.
nonisolated struct ProviderUsageLedgerStore: Sendable {
    /// Far smaller than the scan caches need: at most a few hundred days times a
    /// couple of providers. A file past this is corrupt, not large.
    static let maximumArtifactBytes = 1 * 1024 * 1024

    static var fileName: String {
        "provider-usage-observations-v\(ProviderUsageLedger.currentSchemaVersion).json"
    }

    let directory: URL

    /// `~/Library/Application Support/MeterBar`, alongside the cost caches.
    static var applicationSupport: ProviderUsageLedgerStore? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return ProviderUsageLedgerStore(
            directory: support.appendingPathComponent("MeterBar", isDirectory: true)
        )
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> ProviderUsageLedger {
        Self.load(from: fileURL)
    }

    func save(_ ledger: ProviderUsageLedger) throws {
        try Self.save(ledger, to: fileURL)
    }

    /// `.secondsSince1970`, pinned on both sides, matching `CostScanCacheStore`.
    ///
    /// Pinned rather than left to independently defaulted instances that only
    /// happen to agree today, because a mismatch here would not throw: the
    /// payload keys dictionaries by `Date`, and Foundation's own default
    /// (`.deferredToDate`) also writes a bare number — just one counted from
    /// 2001 rather than 1970. Reading one as the other decodes cleanly and lands
    /// every day thirty-one years from where it belongs. Change one of these two
    /// and you must change the other.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Loads the ledger, or an empty one when the artifact is missing, oversized,
    /// unreadable, or written by a different schema.
    ///
    /// A schema mismatch drops rather than migrates: the cost is one poll
    /// interval of accumulation, and `fileName` is schema-versioned so the two
    /// generations never share a path. A *time-zone* change is deliberately not
    /// grounds to drop. Moving zones is routine — travel, a corrected system
    /// setting, DST on a machine configured by offset — and discarding here would
    /// silently destroy up to `retainedDays` of the only copy of Cursor's and
    /// OpenRouter's history, which neither provider will re-serve.
    ///
    /// So the days already recorded keep the boundary they were recorded
    /// against, and the ledger is re-anchored to the current zone for the days
    /// still to come. That leaves a bounded error on the one or two days
    /// straddling the move — strictly better than total, irreversible loss.
    /// Entries dated in UTC are unaffected either way; their boundary never
    /// depended on the system zone.
    static func load(from url: URL, maximumBytes: Int = maximumArtifactBytes) -> ProviderUsageLedger {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              var ledger = try? decoder.decode(ProviderUsageLedger.self, from: data),
              ledger.schemaVersion == ProviderUsageLedger.currentSchemaVersion else {
            return ProviderUsageLedger()
        }
        ledger.timeZoneIdentifier = TimeZone.current.identifier
        return ledger
    }

    /// Writes the ledger through, or throws describing which stage failed.
    ///
    /// Reuses `CostScanCacheStoreError` rather than declaring a parallel set: the
    /// stages are identical, and the reasons are already reduced to errno or
    /// domain+code so a `privacy: .public` log line cannot leak a home-directory
    /// path.
    static func save(_ ledger: ProviderUsageLedger, to url: URL, maximumBytes: Int = maximumArtifactBytes) throws {
        let data: Data
        do {
            data = try encoder.encode(ledger)
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
    }
}
