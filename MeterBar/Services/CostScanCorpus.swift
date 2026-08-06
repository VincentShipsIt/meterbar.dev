import Foundation

/// One transcript on disk, with the metadata the scan needs before deciding
/// whether to open it.
nonisolated struct CostScanFile: Sendable {
    let url: URL
    let size: Int
    let modified: Date

    /// The per-file cache key. Standardized so `/tmp/...` and `/private/tmp/...`
    /// resolve to one entry rather than two half-read ones.
    var cacheKey: String { url.standardizedFileURL.path }
}

/// Enumerates the `.jsonl` transcripts under a provider root, newest first.
nonisolated enum CostScanCorpus {
    /// Newest modification date first.
    ///
    /// Ordering is what makes a budgeted refresh useful rather than arbitrary.
    /// The visible summary is a 30-day window, and the transcripts that fall in
    /// it are exactly the recently-written ones — so spending the budget newest
    /// first makes the number on screen correct after the first pass, while the
    /// older archive (which only moves the lifetime total) catches up over
    /// subsequent refreshes.
    static func transcripts(in root: URL) -> [CostScanFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [CostScanFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files.append(
                CostScanFile(
                    url: url,
                    size: values.fileSize ?? 0,
                    modified: values.contentModificationDate ?? .distantPast
                )
            )
        }

        // Path breaks ties so a corpus written in one burst still enumerates
        // deterministically — otherwise a budgeted test would be a coin flip.
        return files.sorted {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
        }
    }
}
