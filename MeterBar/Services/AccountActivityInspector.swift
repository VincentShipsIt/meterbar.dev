import Foundation

/// Detects when an account was last actually *used* by probing modification
/// dates of the files its CLI/app writes during a session.
///
/// The probe is intentionally shallow (a config directory plus its immediate
/// children) — Claude Code and Codex both touch top-level entries constantly
/// while a session runs (`sessions/`, `session-env/`, sqlite WAL files), so a
/// depth-1 scan is a reliable and cheap activity signal.
/// `nonisolated`: pure filesystem probing with no shared state — opts out of
/// the app target's default MainActor isolation so callers can (and must)
/// run the scans off the main actor.
nonisolated enum AccountActivityInspector {
    /// Newest modification date among a directory and its top-level entries,
    /// or nil when the directory doesn't exist.
    static func lastActivity(inDirectory path: String) -> Date? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        var newest = modificationDate(atPath: path)
        let entries = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        for entry in entries {
            let entryPath = (path as NSString).appendingPathComponent(entry)
            guard let date = modificationDate(atPath: entryPath) else { continue }
            if newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return newest
    }

    /// Newest modification date among the paths that exist, or nil when none do.
    static func lastActivity(atPaths paths: [String]) -> Date? {
        paths.compactMap(modificationDate(atPath:)).max()
    }

    // MARK: - Provider probes

    /// Claude Code writes session state under its config directory
    /// (`CLAUDE_CONFIG_DIR`, default `~/.claude`), one directory per account.
    static func claudeCodeActivity(configDirectory: String?) -> Date? {
        let trimmed = configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (trimmed?.isEmpty == false ? trimmed : nil)
            ?? "\(ServiceSupport.realHomeDirectory())/.claude"
        return lastActivity(inDirectory: directory)
    }

    /// Codex CLI keeps all state (sqlite + WAL, caches, snapshots) under
    /// `CODEX_HOME`, defaulting to `~/.codex`.
    static func codexCliActivity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> Date? {
        lastActivity(inDirectory: CodexHomeDirectory.path(
            environment: environment,
            realHomeDirectory: realHomeDirectory
        ))
    }

    static func codexCliActivity(homeDirectory: String?) -> Date? {
        let account = CodexAccount(
            id: CodexAccount.defaultID,
            name: CodexAccount.defaultName,
            homeDirectory: homeDirectory
        )
        return lastActivity(inDirectory: CodexHomeDirectory.path(for: account))
    }

    /// Cursor continuously checkpoints its state database while running; the
    /// WAL sibling is the hottest file. Mirrors the candidate paths used by
    /// `CursorLocalService.getCursorDatabasePath`.
    static func cursorActivity() -> Date? {
        let homeDir = ServiceSupport.realHomeDirectory()
        let databasePaths = [
            "\(homeDir)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(homeDir)/Library/Application Support/Cursor/state.vscdb",
            "\(homeDir)/.config/Cursor/User/globalStorage/state.vscdb",
            "\(homeDir)/Library/Application Support/Cursor/User/workspaceStorage/state.vscdb",
            "\(homeDir)/Library/Application Support/Cursor/globalStorage/state.vscdb"
        ]
        return lastActivity(atPaths: databasePaths.flatMap { [$0, "\($0)-wal"] })
    }

    private static func modificationDate(atPath path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
