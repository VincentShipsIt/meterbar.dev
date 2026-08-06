import Foundation

/// Filesystem guards the cost scan applies before walking a directory tree.
/// Split out of `CostTracker` (audit C1d).
enum CostScanFileSystem {
    nonisolated static func isLocalDirectory(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let values = try? standardized.resourceValues(forKeys: [.volumeIsLocalKey])
        // Intentionally skip network and mounted volumes; cost scans should stay
        // fast and avoid surprising remote I/O when users point accounts there.
        return values?.volumeIsLocal != false
    }

    /// Every `.jsonl` transcript under `root`, sorted by path.
    ///
    /// The scanners used to parse straight out of the enumerator. Collecting
    /// first is what lets the parse fan out, and the sort is what keeps the
    /// answer stable: `FileManager` yields directory entries in whatever order
    /// the volume hands them back, and both scanners have order-sensitive
    /// results — Codex deduplicates first-event-wins, and summing `Double`
    /// costs is not associative. Sorted input means two scans of the same tree
    /// agree bit for bit, sequential or parallel.
    ///
    /// Directory-ness is not checked here. A directory named `foo.jsonl` simply
    /// fails to open in the reader, the same as any other unreadable file.
    nonisolated static func transcriptFiles(
        in root: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) -> [URL] {
        guard isLocalDirectory(root) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
