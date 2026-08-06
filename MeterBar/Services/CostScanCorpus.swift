import Foundation

/// Identity and content stamp used to decide whether cached progress still
/// describes the file at a path.
nonisolated struct CostScanFileStamp: Codable, Equatable, Sendable {
    let size: Int
    let modified: Double
    let fileID: UInt64?

    static func read(at url: URL) -> CostScanFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return CostScanFileStamp(
            size: size,
            modified: modified.timeIntervalSince1970,
            fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    func matches(_ other: CostScanFileStamp) -> Bool {
        guard size == other.size, modified == other.modified else { return false }
        guard let fileID, let otherID = other.fileID else { return true }
        return fileID == otherID
    }

    /// A growing or half-read file may resume only when the volume proves it is
    /// the same inode. Without an identifier, re-reading is slower but safe.
    func isSameFile(as other: CostScanFileStamp) -> Bool {
        guard let fileID, let otherID = other.fileID else { return false }
        return fileID == otherID
    }
}

/// One transcript on disk, with the metadata the scan needs before deciding
/// whether to open it.
nonisolated struct CostScanFile: Sendable {
    let url: URL
    let stamp: CostScanFileStamp

    var size: Int { stamp.size }
    var modified: Date { Date(timeIntervalSince1970: stamp.modified) }

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
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [CostScanFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let stamp = CostScanFileStamp.read(at: url) else { continue }
            files.append(
                CostScanFile(
                    url: url,
                    stamp: stamp
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
