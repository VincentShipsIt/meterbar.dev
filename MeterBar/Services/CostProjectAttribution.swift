import Foundation

/// Derives a per-project/worktree identifier strictly from the file-system
/// location of a scanned transcript — never from prompt content, credentials,
/// or git metadata (issue #270). Every session attributes to exactly one
/// bucket; a session this can't place lands in the explicit `unknownProjectID`
/// bucket rather than being dropped or guessed at.
enum CostProjectAttribution {
    /// Explicit fallback bucket for sessions with no derivable project.
    static let unknownProjectID = "unknown"

    /// Claude Code stores each transcript under
    /// `<projects-root>/<encoded-cwd>/<session>.jsonl`, where the encoded
    /// directory name is the session's absolute working directory with both
    /// "/" and "." collapsed to "-". Computed once per file — unlike
    /// `usageOrigin`, which can vary per event — because project identity is
    /// a property of where the file lives, not of any one message inside it.
    ///
    /// The collapse is lossy: a literal "-" inside a real path segment can't
    /// be told apart from an encoded separator. This is an accepted,
    /// best-effort reconstruction, not a byte-exact decode.
    nonisolated static func claudeProjectID(forTranscriptURL url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return unknownProjectID }

        let relative = filePath
            .dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let encodedDirectory = relative.split(separator: "/").first, !encodedDirectory.isEmpty else {
            return unknownProjectID
        }

        return sanitize(encodedDirectoryName: String(encodedDirectory))
    }

    /// Codex names the session's real, unencoded working directory once per
    /// session in `session_meta.payload.cwd` — a legitimate non-prompt-content
    /// field, distinct from anything the user typed. Sessions the scanner
    /// can't attach a `cwd` to (including every event read from the flat
    /// SQLite log format, which carries no path field at all) resolve to
    /// `unknownProjectID` — correct behavior, never a guess.
    nonisolated static func codexProjectID(cwd: String?) -> String {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unknownProjectID
        }
        return sanitize(absolutePath: cwd)
    }

    /// Strips the encoded real-home-directory prefix so a displayed
    /// identifier never leaks a full home-directory path, then reads dashes
    /// in the remainder as path separators.
    nonisolated private static func sanitize(encodedDirectoryName raw: String) -> String {
        let homeEncoded = "-" + ServiceSupport.realHomeDirectory()
            .split(separator: "/")
            .joined(separator: "-")
        guard raw.hasPrefix(homeEncoded) else { return unknownProjectID }

        let remainder = String(raw.dropFirst(homeEncoded.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !remainder.isEmpty else { return unknownProjectID }
        return remainder.replacingOccurrences(of: "-", with: "/")
    }

    /// Strips the real home-directory prefix from an absolute path so a
    /// displayed identifier never leaks a full home-directory path.
    nonisolated private static func sanitize(absolutePath raw: String) -> String {
        let home = ServiceSupport.realHomeDirectory()
        guard raw.hasPrefix(home) else { return unknownProjectID }

        let remainder = String(raw.dropFirst(home.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !remainder.isEmpty else { return unknownProjectID }
        return remainder
    }
}
