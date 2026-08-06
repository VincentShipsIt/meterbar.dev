import Foundation

/// Guards the cost scan applies to its raw inputs — which trees it will walk,
/// and which transcript lines are worth parsing.
/// Split out of `CostTracker` (audit C1d).
enum CostScanFileSystem {
    /// Largest transcript line the scanners will hand to `JSONSerialization`.
    ///
    /// Both CLIs write pasted files, base64 blobs and raw tool output straight
    /// into a single `.jsonl` line, so a transcript can carry multi-megabyte
    /// records that are never usage records. Parsing one costs seconds of CPU
    /// and a transient allocation the size of the line, and the result is
    /// always discarded.
    ///
    /// 4 MiB is measured, not guessed. On a local corpus of 351k Claude lines
    /// and 1.44M Codex lines the largest *usage-bearing* line was 150,055 B
    /// (146.5 KiB) for Claude and 831 B for Codex — the cap leaves roughly 28x
    /// headroom over the worst real record. It skipped 108 Codex lines and 0
    /// Claude lines, against a largest line overall of 56.7 MB.
    nonisolated static let maximumLineBytes = 4 * 1024 * 1024

    /// Whether a transcript line is small enough to be worth parsing.
    nonisolated static func isScannableLine(_ line: Data) -> Bool {
        line.count <= maximumLineBytes
    }

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
}
