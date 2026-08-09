import Foundation

/// Coarse provenance for a resolved provider CLI. This is intentionally an
/// observability signal rather than an execution gate: developer CLIs are
/// routinely installed as unsigned or ad-hoc-signed npm/bun shims.
nonisolated enum CLIBinaryTrust: Equatable, Sendable {
    case wellKnown
    case unexpected
}

/// Resolves a CLI executable by scanning `PATH` and the common install
/// locations MeterBar runs from (Homebrew, npm-global, yarn, bun, volta, etc.).
///
/// This was previously private to `ClaudeCodeCLIUsageService`; it is factored
/// out so provider-readiness diagnostics can ask "is `codex` / `claude` / `grok` on
/// PATH?" without re-deriving the same fallback list.
nonisolated enum CLIBinaryLocator {
    private static let systemBinaryDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static let trustLogState = CLIBinaryTrustLogState()

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
        home: String = ServiceSupport.realHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        if let overrideEnvVar,
           let override = environment[overrideEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            // An explicit path is deliberate operator configuration. Its
            // location carries no surprise signal, regardless of directory.
            logUnexpectedResolutionIfNeeded(
                command: command,
                resolvedPath: override,
                home: home,
                isUserOverride: true
            )
            return override
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(command)" }

        let fallbacks = fallbackCandidates(for: command, home: home)

        guard let resolvedPath = (pathCandidates + fallbacks).first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) else {
            return nil
        }

        logUnexpectedResolutionIfNeeded(command: command, resolvedPath: resolvedPath, home: home)
        return resolvedPath
    }

    /// Classifies a resolved executable by exact, normalized parent-directory
    /// equality. Substring matching would incorrectly trust paths such as
    /// `/tmp/opt/homebrew/bin`, while raw comparison would flag harmless `//`
    /// and trailing-slash variants.
    ///
    /// `isUserOverride` represents a path supplied through the provider's
    /// override environment variable. Such a path is deliberate user intent
    /// and is therefore `.wellKnown` regardless of location.
    ///
    /// Code-signature enforcement was considered and rejected. Claude, Codex,
    /// and Grok are frequently unsigned or ad-hoc-signed npm/bun shims, so a
    /// signature requirement would reject most legitimate installations while
    /// providing little assurance about the script/runtime ultimately executed.
    static func trust(
        forResolvedPath resolvedPath: String,
        home: String,
        isUserOverride: Bool = false
    ) -> CLIBinaryTrust {
        guard !isUserOverride else { return .wellKnown }

        let parentDirectory = normalizedPath(
            (normalizedPath(resolvedPath) as NSString).deletingLastPathComponent
        )
        let wellKnownDirectories = Set(
            (fallbackDirectories(home: home) + systemBinaryDirectories).map(normalizedPath)
        )
        return wellKnownDirectories.contains(parentDirectory) ? .wellKnown : .unexpected
    }

    /// Clears process-lifetime notice deduplication so tests remain independent
    /// of execution order.
    static func resetTrustLogStateForTesting() {
        trustLogState.reset()
    }

    static var trustLogCountForTesting: Int {
        trustLogState.count
    }

    private static func logUnexpectedResolutionIfNeeded(
        command: String,
        resolvedPath: String,
        home: String,
        isUserOverride: Bool = false
    ) {
        guard trust(
            forResolvedPath: resolvedPath,
            home: home,
            isUserOverride: isUserOverride
        ) == .unexpected else {
            return
        }

        let normalizedResolvedPath = normalizedPath(resolvedPath)
        let key = "\(command)\u{0}\(normalizedResolvedPath)"
        guard trustLogState.insert(key) else { return }

        let redactedPath = ServiceSupport.compactPathForDisplay(
            normalizedResolvedPath,
            realHomeDirectory: home
        )
        AppLog.app.notice(
            "Resolved \(command, privacy: .public) CLI from an unexpected path: \(redactedPath, privacy: .public)"
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Whether `command` resolves to an executable.
    static func isAvailable(command: String, overrideEnvVar: String? = nil) -> Bool {
        resolve(command: command, overrideEnvVar: overrideEnvVar) != nil
    }
}

/// Lock-protected because provider-readiness polling may resolve the same CLI
/// concurrently. The set is bounded by the small number of unique command/path
/// pairs seen during one app process.
nonisolated private final class CLIBinaryTrustLogState: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func insert(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }

    func reset() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }
}
