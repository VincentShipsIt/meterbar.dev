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
}
