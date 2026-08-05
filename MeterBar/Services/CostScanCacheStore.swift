import Foundation

/// Persistence for the incremental scan cache.
///
/// Deliberately the same shape as `CostSummaryStore`: Application Support,
/// versioned filename, `JSONEncoder`, `SecureFileWriter` for the atomic 0600
/// write, and a decode that answers `nil` rather than throwing. The scan cache
/// is a second cache, not a second mechanism.
nonisolated enum CostScanCacheStore {
    /// Ceiling on the artifact, applied on the way in *and* out.
    ///
    /// `JSONDecoder` materialises roughly ten times a payload's size in live
    /// objects, so decoding an unbounded cache file is a multi-gigabyte memory
    /// spike — the failure mode CodexBar hit. 64 MB holds MeterBar's ~10 GB
    /// corpus reduced to day buckets with room to spare, and caps the worst case
    /// at a few hundred megabytes of transient decode.
    static let maximumArtifactBytes = 64 * 1024 * 1024

    /// The schema version lives in the *name*, not just the payload, so an older
    /// build and a newer one never overwrite each other's cache and force a
    /// rescan on every alternating launch.
    static let cacheFileName = "cost-scan-cache-v\(CostScanCacheFile.currentSchemaVersion).json"

    static var cacheURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return support
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    /// Reads the cache, treating every failure the same way: no cache.
    ///
    /// Missing file, truncated JSON, a payload from a future build, a payload
    /// from different parsing rules, one too large to decode safely — all of them
    /// degrade to a full rescan, which is slow but always right.
    static func load(from url: URL, maximumBytes: Int = maximumArtifactBytes) -> CostScanCacheFile? {
        // Stat before read: an oversized artifact must never be loaded into
        // memory at all, let alone handed to the decoder.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= maximumBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumBytes,
              let file = try? JSONDecoder().decode(CostScanCacheFile.self, from: data),
              file.schemaVersion == CostScanCacheFile.currentSchemaVersion,
              file.parserVersion == CostScanValues.costCacheParserVersion else {
            return nil
        }
        return file
    }

    static func save(
        _ file: CostScanCacheFile,
        to url: URL,
        maximumBytes: Int = maximumArtifactBytes
    ) throws {
        let encoder = JSONEncoder()
        // No `.prettyPrinted`/`.sortedKeys` here, unlike `CostSummaryStore`.
        // That file is a few kilobytes a human might open; this one is millions
        // of integers no one reads, where the formatting would cost real time
        // and roughly double the bytes on disk.
        let data = try encoder.encode(file)
        // `CostScanCache.snapshot` already trims to a value budget, so this is
        // the backstop for an estimate that ran wide. Writing an artifact the
        // next launch would refuse costs disk and buys nothing.
        guard data.count <= maximumBytes else {
            throw CostScanCacheStoreError.artifactTooLarge(bytes: data.count, limit: maximumBytes)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SecureFileWriter.write(data, to: url)
        removeSupersededCaches(alongside: url)
    }

    /// Deletes caches left by other schema versions in the same directory.
    ///
    /// Without this, every bump strands the previous artifact — up to
    /// `maximumArtifactBytes` of dead weight per version, in a directory the
    /// user never looks at. Best effort: failing to tidy up is not a reason to
    /// fail a write that already succeeded.
    private static func removeSupersededCaches(alongside url: URL) {
        let directory = url.deletingLastPathComponent()
        let current = url.lastPathComponent
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for sibling in siblings {
            let name = sibling.lastPathComponent
            guard name != current,
                  name.hasPrefix("cost-scan-cache-v"),
                  name.hasSuffix(".json") else {
                continue
            }
            try? FileManager.default.removeItem(at: sibling)
        }
    }
}

nonisolated enum CostScanCacheStoreError: LocalizedError {
    case artifactTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .artifactTooLarge(bytes, limit):
            return "Scan cache is \(bytes) bytes, over the \(limit) byte limit"
        }
    }
}
