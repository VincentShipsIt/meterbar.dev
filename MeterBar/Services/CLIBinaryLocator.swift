import Foundation

/// Resolves a CLI executable by scanning `PATH` and the common install
/// locations MeterBar runs from (Homebrew, npm-global, yarn, bun, volta, etc.).
///
/// This was previously private to `ClaudeCodeCLIUsageService`; it is factored
/// out so provider-readiness diagnostics can ask "is `codex` / `claude` on
/// PATH?" without re-deriving the same fallback list.
nonisolated enum CLIBinaryLocator {
    /// The install directories the fallbacks draw from, in priority order.
    /// Kept in sync with the reconnect script's `export PATH` list.
    static func fallbackDirectories(home: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
        ]
    }

    /// The install-location fallbacks checked after `PATH`, for `command`.
    private static func fallbackCandidates(for command: String, home: String) -> [String] {
        fallbackDirectories(home: home).map { "\($0)/\(command)" }
    }

    /// `PATH` from `environment` with the fallback install directories appended
    /// (existing entries keep priority; duplicates are dropped).
    ///
    /// GUI apps inherit launchd's bare PATH, so even when MeterBar resolves a
    /// CLI binary via the fallbacks, the *spawned* CLI can fail to find its own
    /// runtime — `claude` needs `node`, typically in `/opt/homebrew/bin`.
    /// Spawn child processes with this PATH instead of the inherited one.
    static func augmentedPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = ServiceSupport.realHomeDirectory()
    ) -> String {
        let existing = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set(existing)
        var entries = existing
        for directory in fallbackDirectories(home: home) where seen.insert(directory).inserted {
            entries.append(directory)
        }
        return entries.joined(separator: ":")
    }

    /// The resolved absolute path to `command`, or nil if it isn't found.
    ///
    /// - Parameter overrideEnvVar: an environment variable (e.g. `CLAUDE_CLI_PATH`)
    ///   whose value, if it points at an executable, wins over any PATH lookup.
    static func resolve(
        command: String,
        overrideEnvVar: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let overrideEnvVar,
           let override = environment[overrideEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(command)" }

        let fallbacks = fallbackCandidates(for: command, home: ServiceSupport.realHomeDirectory())

        return (pathCandidates + fallbacks).first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Whether `command` resolves to an executable.
    static func isAvailable(command: String, overrideEnvVar: String? = nil) -> Bool {
        resolve(command: command, overrideEnvVar: overrideEnvVar) != nil
    }
}
