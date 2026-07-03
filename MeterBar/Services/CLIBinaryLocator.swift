import Foundation

/// Resolves a CLI executable by scanning `PATH` and the common install
/// locations MeterBar runs from (Homebrew, npm-global, yarn, bun, volta, etc.).
///
/// This was previously private to `ClaudeCodeCLIUsageService`; it is factored
/// out so provider-readiness diagnostics can ask "is `codex` / `claude` on
/// PATH?" without re-deriving the same fallback list.
enum CLIBinaryLocator {
    /// The install-location fallbacks checked after `PATH`, for `command`.
    private static func fallbackCandidates(for command: String, home: String) -> [String] {
        [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(home)/.local/bin/\(command)",
            "\(home)/.npm-global/bin/\(command)",
            "\(home)/.yarn/bin/\(command)",
            "\(home)/.bun/bin/\(command)",
            "\(home)/.volta/bin/\(command)",
        ]
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
