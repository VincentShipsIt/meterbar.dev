import Foundation

/// Permission posture for a resumed session.
///
/// v1 default is `.safe`. `.bypass` maps to `--dangerously-skip-permissions`
/// and is only ever emitted when the caller has separately acknowledged it —
/// the builder refuses to silently escalate.
nonisolated enum WakePermissionMode: String, Codable, Equatable, Sendable {
    case safe
    case bypass
}

/// A fully-resolved child invocation: executable + argument array + environment
/// + working directory. Built as arrays, never a shell string — nothing here is
/// ever passed through `/bin/sh`.
nonisolated struct WakeCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String
}

/// Builds the `claude` resume invocation for a candidate.
nonisolated enum WakeCommandBuilder {
    /// The resume prompt default. Deliberately minimal.
    static let defaultPrompt = "continue"

    /// Build the command for `candidate` under `account`.
    ///
    /// - Parameters:
    ///   - permissionMode: requested posture.
    ///   - bypassAcknowledged: gate for `.bypass`. When `false`, a `.bypass`
    ///     request is downgraded to `.safe` — permission bypass is never the
    ///     silent default.
    static func build(
        executable: String,
        candidate: WakeSessionCandidate,
        account: ClaudeCodeAccount,
        bounds: WakeBounds,
        prompt: String = defaultPrompt,
        permissionMode: WakePermissionMode = .safe,
        bypassAcknowledged: Bool = false,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WakeCommand {
        var arguments = [
            "-r", candidate.sessionID,
            "-p", prompt,
            "--print",
            "--output-format", "text",
            "--max-turns", String(bounds.maxTurns)
        ]

        let effectiveMode: WakePermissionMode = (permissionMode == .bypass && bypassAcknowledged) ? .bypass : .safe
        switch effectiveMode {
        case .safe:
            // Explicit conservative posture; never auto-approves tool use.
            arguments.append(contentsOf: ["--permission-mode", "default"])
        case .bypass:
            arguments.append("--dangerously-skip-permissions")
        }

        var environment = baseEnvironment
        // Same PATH gap as ClaudeCodeCLIUsageService: a GUI-launched MeterBar
        // inherits launchd's bare PATH, and the resumed `claude` needs `node`.
        environment["PATH"] = CLIBinaryLocator.augmentedPATH(environment: baseEnvironment)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        if let configDirectory = account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDirectory.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        }

        let workingDirectory = candidate.workingDirectory
            ?? account.configDirectory
            ?? FileManager.default.currentDirectoryPath
        return WakeCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}
