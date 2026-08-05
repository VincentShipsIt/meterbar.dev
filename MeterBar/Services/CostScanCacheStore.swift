import Foundation

/// Persistence for the incremental scan cache.
///
/// Deliberately the same shape as `CostSummaryStore`: Application Support,
/// versioned filename, `JSONEncoder`, `SecureFileWriter` for the atomic 0600
/// write, and a decode that answers `nil` rather than throwing. The scan cache
/// is a second cache, not a second mechanism.
nonisolated enum CostScanCacheStore {
    static let cacheFileName = "cost-scan-cache-v1.json"

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
    /// Missing file, truncated JSON, a payload from a future build — all of them
    /// degrade to a full rescan, which is slow but always right.
    static func load(from url: URL) -> CostScanCacheFile? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CostScanCacheFile.self, from: data),
              file.schemaVersion == CostScanCacheFile.currentSchemaVersion else {
            return nil
        }
        return file
    }

    static func save(_ file: CostScanCacheFile, to url: URL) throws {
        let encoder = JSONEncoder()
        // No `.prettyPrinted`/`.sortedKeys` here, unlike `CostSummaryStore`.
        // That file is a few kilobytes a human might open; this one is millions
        // of integers no one reads, where the formatting would cost real time
        // and roughly double the bytes on disk.
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SecureFileWriter.write(data, to: url)
    }
}
