import Foundation

/// On-disk envelope for the cached cost summary. Written by the app's
/// CostTracker after each scan; read back by the app on launch and by
/// `meterbar cost` (which reports the app's scan instead of re-implementing
/// a divergent one).
nonisolated public struct CostSummaryCache: Codable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let summary: CostSummary
    public let lastScanDate: Date

    public init(summary: CostSummary, lastScanDate: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.summary = summary
        self.lastScanDate = lastScanDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Version 1 had no envelope version field. Its DailyTokenUsage rows
        // decode missing attribution arrays as nil and missing daily
        // cache-creation data as explicitly non-authoritative.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        summary = try container.decode(CostSummary.self, forKey: .summary)
        lastScanDate = try container.decode(Date.self, forKey: .lastScanDate)
    }

    fileprivate var migratedToCurrentVersion: CostSummaryCache {
        CostSummaryCache(summary: summary, lastScanDate: lastScanDate)
    }
}

/// Single owner of the cost-summary cache location and encoding
/// (`~/Library/Application Support/MeterBar/cost-summary-v2.json`).
nonisolated public enum CostSummaryStore {
    static let cacheFileName = "cost-summary-v2.json"
    static let legacyCacheFileName = "cost-summary-v1.json"

    public static var cacheURL: URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return supportDirectory
            .appendingPathComponent("MeterBar", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    static var legacyCacheURL: URL? {
        cacheURL?
            .deletingLastPathComponent()
            .appendingPathComponent(legacyCacheFileName)
    }

    public static func load() -> CostSummaryCache? {
        guard let cacheURL, let legacyCacheURL else { return nil }
        return load(currentURL: cacheURL, legacyURL: legacyCacheURL)
    }

    /// Testable migration seam. The v1 file is copied forward only after it
    /// decodes successfully; it remains in place as a recoverable fallback.
    static func load(currentURL: URL, legacyURL: URL) -> CostSummaryCache? {
        if FileManager.default.fileExists(atPath: currentURL.path) {
            guard let cache = decode(from: currentURL),
                  cache.schemaVersion <= CostSummaryCache.currentSchemaVersion else {
                return nil
            }
            if cache.schemaVersion == CostSummaryCache.currentSchemaVersion {
                return cache
            }

            let migrated = cache.migratedToCurrentVersion
            try? save(migrated, to: currentURL)
            return migrated
        }

        guard let legacy = decode(from: legacyURL),
              legacy.schemaVersion < CostSummaryCache.currentSchemaVersion else {
            return nil
        }
        let migrated = legacy.migratedToCurrentVersion
        try? save(migrated, to: currentURL)
        return migrated
    }

    private static func decode(from url: URL) -> CostSummaryCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CostSummaryCache.self, from: data)
    }

    static func save(_ cache: CostSummaryCache) throws {
        guard let cacheURL else { return }
        try save(cache, to: cacheURL)
    }

    static func save(_ cache: CostSummaryCache, to cacheURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(cache)
        try SecureFileWriter.write(data, to: cacheURL)
    }
}
