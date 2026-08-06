import Foundation

/// Derives a per-project/worktree identifier strictly from the file-system
/// location of a scanned transcript — never from prompt content, credentials,
/// or git metadata (issue #270). Every session attributes to exactly one
/// bucket; a session this can't place lands in the explicit `unknownProjectID`
/// bucket rather than being dropped or guessed at.
enum CostProjectAttribution {
    /// Explicit fallback bucket for sessions with no derivable project.
    /// `nonisolated` because every caller — both `sanitize` overloads and the
    /// two scanners — reads it off the main actor while parsing transcripts.
    nonisolated static let unknownProjectID = "unknown"

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
    ///
    /// The prefix must be followed by the encoded separator, so a sibling
    /// directory that merely starts with the same characters (home
    /// `/Users/alice`, encoded `-Users-alicexyz`) falls into `unknown`
    /// instead of reporting a fabricated "xyz" project.
    nonisolated private static func sanitize(encodedDirectoryName raw: String) -> String {
        let homeEncoded = "-" + homeDirectory()
            .split(separator: "/")
            .joined(separator: "-")
        guard raw.hasPrefix(homeEncoded + "-") else { return unknownProjectID }

        let remainder = String(raw.dropFirst(homeEncoded.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !remainder.isEmpty else { return unknownProjectID }
        return remainder.replacingOccurrences(of: "-", with: "/")
    }

    /// Strips the real home-directory prefix from an absolute path so a
    /// displayed identifier never leaks a full home-directory path.
    ///
    /// The prefix must end on a directory boundary, so a sibling path that
    /// shares the home directory's leading characters (home `/Users/alice`,
    /// path `/Users/alice-work/app`) resolves to `unknown` rather than the
    /// fabricated project "-work/app".
    nonisolated private static func sanitize(absolutePath raw: String) -> String {
        let home = homeDirectory()
        guard raw.hasPrefix(home + "/") else { return unknownProjectID }

        let remainder = String(raw.dropFirst(home.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !remainder.isEmpty else { return unknownProjectID }
        return remainder
    }

    /// Home directory without a trailing separator. Both `sanitize` overloads
    /// append their own boundary character, so a `HOME` that happens to end in
    /// "/" would otherwise never match and send every session to `unknown`.
    ///
    /// Resolved once per process rather than per call. `realHomeDirectory()`
    /// goes through `getpwuid`, which leaves its result in a shared static
    /// object and is not safe to call from several threads at once — and both
    /// scanners now reach this from worker threads, once per Claude transcript
    /// and once per Codex usage event. The value cannot change while the
    /// process runs, so a `static let` (initialized exactly once, under the
    /// runtime's own lock) is both the safe answer and strictly less work.
    nonisolated private static let cachedHomeDirectory: String = {
        var home = ServiceSupport.realHomeDirectory()
        while home.count > 1, home.hasSuffix("/") {
            home.removeLast()
        }
        return home
    }()

    nonisolated private static func homeDirectory() -> String {
        cachedHomeDirectory
    }
}
