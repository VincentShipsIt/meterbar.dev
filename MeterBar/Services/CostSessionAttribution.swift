import Foundation

/// Stable, path-free session identifiers for cost rows (issue #391).
///
/// Project identity stays on `CostProjectAttribution`. This only names the
/// session itself: a filename stem or conversation id, never a working
/// directory, branch, remote, prompt, or credential.
enum CostSessionAttribution {
    /// Explicit fallback when a transcript has no usable session identity.
    nonisolated static let unknownSessionID = "unknown"

    /// Filename stem with directories and extensions stripped. Codex conversation
    /// UUIDs and Claude transcript names already look like this; a raw path is
    /// reduced to its last component so home directories never reach the cache.
    nonisolated static func stableID(from url: URL) -> String {
        sanitize(url.deletingPathExtension().lastPathComponent)
    }

    nonisolated static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unknownSessionID }
        if trimmed.contains("/") {
            return sanitize(URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent)
        }
        return trimmed
    }
}
