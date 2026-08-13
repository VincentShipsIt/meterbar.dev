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

    var cacheKey: String { CostScanCorpus.cacheKey(for: url) }
}

/// The result of walking one provider root: the transcripts the walk could
/// stamp, plus what it could *not* see.
///
/// Callers prune their cache against the keys a walk produced, so a walk has to
/// say how much of the tree it actually covered. Silently dropping an entry
/// makes a live transcript indistinguishable from a deleted one, and pruning
/// against that discards its resumable offset.
nonisolated struct CostScanCorpusListing: Sendable {
    /// Stamped regular files, newest modification date first.
    let files: [CostScanFile]
    /// Cache keys for `.jsonl` files the walk listed but could not stamp. They
    /// exist; this lookup simply failed. They keep their cache records and are
    /// retried on the next refresh.
    let unreadableKeys: Set<String>
    /// `false` when part of the tree was never walked — an unreadable
    /// directory, or an enumerator that could not be created. Nothing may be
    /// pruned against a listing that is not complete.
    let isComplete: Bool

    static let empty = CostScanCorpusListing(files: [], unreadableKeys: [], isComplete: true)
}

/// Accumulates listings across the several roots one provider scans, and the
/// keys the scan actually visited, into the single retention set the session
/// prunes against.
nonisolated struct CostScanCorpusCoverage {
    /// Keys the scan reached. Doubles as the dedup set for overlapping roots.
    private var scanned: Set<String> = []
    /// Kept separately from `scanned`: one root failing to stat a path says
    /// nothing about a sibling root that reads it fine, so an unreadable key
    /// must never make the file look already-visited.
    private var unreadable: Set<String> = []
    private(set) var isComplete = true

    /// Everything the provider's cache is allowed to keep.
    var retainedKeys: Set<String> { scanned.union(unreadable) }

    mutating func add(_ listing: CostScanCorpusListing) {
        unreadable.formUnion(listing.unreadableKeys)
        isComplete = isComplete && listing.isComplete
    }

    /// Records a key as visited.
    ///
    /// - Returns: `false` when this scan already visited the key, so callers can
    ///   skip transcripts reached twice through overlapping roots.
    @discardableResult
    mutating func keep(_ key: String) -> Bool {
        scanned.insert(key).inserted
    }
}

/// Enumerates the `.jsonl` transcripts under a provider root, newest first.
nonisolated enum CostScanCorpus {
    /// The per-file cache key. Standardized so `/tmp/...` and `/private/tmp/...`
    /// resolve to one entry rather than two half-read ones.
    static func cacheKey(for url: URL) -> String { url.standardizedFileURL.path }

    /// Newest modification date first.
    ///
    /// Ordering is what makes a budgeted refresh useful rather than arbitrary.
    /// The visible summary is a 30-day window, and the transcripts that fall in
    /// it are exactly the recently-written ones — so spending the budget newest
    /// first makes the number on screen correct after the first pass.
    ///
    /// - Parameter modifiedSince: when set, files whose last write is older than
    ///   this date are not opened. A file that has not been touched cannot hold
    ///   a new in-window event, so walking a multi-gigabyte archive for lifetime
    ///   totals is skipped at the listing layer.
    /// - Parameter fileNames: when set, only transcripts whose last path
    ///   component is in the set are kept (`updates.jsonl` for Grok).
    /// - Parameter stamp: injectable so tests can fail one lookup inside an
    ///   otherwise healthy tree. A stat race cannot be staged on a real file
    ///   system. Production callers use the default.
    static func listing(
        in root: URL,
        modifiedSince: Date? = nil,
        fileNames: Set<String>? = nil,
        stamp: (URL) -> CostScanFileStamp? = { CostScanFileStamp.read(at: $0) }
    ) -> CostScanCorpusListing {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        // A subtree the walk cannot descend into still holds transcripts. The
        // handler keeps the walk going — the rest of the corpus is worth
        // scanning — but the listing can no longer claim to be the whole truth.
        let walk = WalkStatus()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                walk.markIncomplete()
                return true
            }
        ) else {
            return CostScanCorpusListing(files: [], unreadableKeys: [], isComplete: false)
        }

        var files: [CostScanFile] = []
        var unreadableKeys: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let fileNames, !fileNames.contains(url.lastPathComponent) {
                continue
            }
            // A directory or dangling symlink named `*.jsonl` is a definite
            // answer, not a failed lookup: it is not a transcript and never was,
            // so it must stay prunable rather than pin a phantom cache key.
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                unreadableKeys.insert(cacheKey(for: url))
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let stamp = stamp(url) else {
                unreadableKeys.insert(cacheKey(for: url))
                continue
            }
            if let modifiedSince, stamp.modified < modifiedSince.timeIntervalSince1970 {
                continue
            }
            files.append(
                CostScanFile(
                    url: url,
                    stamp: stamp
                )
            )
        }

        // Path breaks ties so a corpus written in one burst still enumerates
        // deterministically — otherwise a budgeted test would be a coin flip.
        return CostScanCorpusListing(
            files: files.sorted {
                $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
            },
            unreadableKeys: unreadableKeys,
            isComplete: walk.isComplete
        )
    }

    /// The enumerator's error handler outlives this call's stack frame, so the
    /// flag it sets cannot be a captured local.
    private final class WalkStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var incomplete = false

        var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !incomplete
        }

        func markIncomplete() {
            lock.lock()
            incomplete = true
            lock.unlock()
        }
    }
}
