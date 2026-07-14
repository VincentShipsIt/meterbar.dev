import Foundation

/// Builds the `codex exec resume` invocation for a blocked Codex candidate.
///
/// Only flags confirmed present on the `codex exec resume` subcommand are used:
/// the positional `SESSION_ID` and `PROMPT`, `-c key=value` config overrides,
/// and `--dangerously-bypass-approvals-and-sandbox`. The posture mapping mirrors
/// the Claude builder's intent:
///
/// - `.safe` pins an explicit, self-contained sandbox: `sandbox_mode` =
///   `workspace-write` (edit the project, no network/system escape) and
///   `approval_policy` = `never` (headless: never block on an approval that
///   cannot be answered — anything needing escalation simply fails closed).
/// - `.bypass` maps to `--dangerously-bypass-approvals-and-sandbox`, and — like
///   the Claude builder — is only emitted when separately acknowledged; an
///   unacknowledged bypass request is silently downgraded to `.safe`.
nonisolated enum CodexWakeCommandBuilder {
    static func build(
        executable: String,
        candidate: WakeSessionCandidate,
        account: CodexAccount,
        bounds: WakeBounds,
        prompt: String = WakeCommandBuilder.defaultPrompt,
        permissionMode: WakePermissionMode = .safe,
        bypassAcknowledged: Bool = false,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WakeCommand {
        var arguments = ["exec", "resume", candidate.sessionID, prompt]

        let effectiveMode: WakePermissionMode = (permissionMode == .bypass && bypassAcknowledged) ? .bypass : .safe
        switch effectiveMode {
        case .safe:
            // TOML-quoted values: `"workspace-write"` parses as a TOML string.
            arguments.append(contentsOf: ["-c", "sandbox_mode=\"workspace-write\""])
            arguments.append(contentsOf: ["-c", "approval_policy=\"never\""])
        case .bypass:
            arguments.append("--dangerously-bypass-approvals-and-sandbox")
        }

        var environment = baseEnvironment
        // Same PATH gap as the Claude runner: a GUI-launched MeterBar inherits
        // launchd's bare PATH, and the resumed `codex` needs `node`/tooling.
        environment["PATH"] = CLIBinaryLocator.augmentedPATH(environment: baseEnvironment)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        if let home = account.homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            environment["CODEX_HOME"] = (home as NSString).standardizingPath
        }

        let workingDirectory = candidate.workingDirectory
            ?? account.homeDirectory
            ?? FileManager.default.currentDirectoryPath
        return WakeCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}
