import Foundation

/// On-disk envelope for the cached cost summary. Written by the app's
/// CostTracker after each scan; read back by the app on launch and by
/// `meterbar cost` (which reports the app's scan instead of re-implementing
/// a divergent one).
public struct CostSummaryCache: Codable, Sendable {
    public let summary: CostSummary
    public let lastScanDate: Date

    public init(summary: CostSummary, lastScanDate: Date) {
        self.summary = summary
        self.lastScanDate = lastScanDate
    }
}

/// Single owner of the cost-summary cache location and encoding
/// (`~/Library/Application Support/MeterBar/cost-summary-v1.json`).
public enum CostSummaryStore {
    static let cacheFileName = "cost-summary-v1.json"

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

    public static func load() -> CostSummaryCache? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CostSummaryCache.self, from: data)
    }

    static func save(_ cache: CostSummaryCache) throws {
        guard let cacheURL else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(cache)
        try data.write(to: cacheURL, options: [.atomic])
    }
}
