import Foundation

// Codex is the second Session Wake provider. It shares the one generic
// `WakeProcessRunner`; only these two axes differ from Claude — the `codex`
// binary/argv, and the absence of a permission-denial gate (Codex `.safe` runs
// set `approval_policy=never`, so a non-zero exit is always a plain failure).

nonisolated extension WakeRunnerDescriptor {
    /// Descriptor for a Codex resume.
    static func codex(
        account: CodexAccount,
        permissionMode: WakePermissionMode,
        bypassAcknowledged: Bool,
        prompt: String,
        baseEnvironment: [String: String]
    ) -> WakeRunnerDescriptor {
        WakeRunnerDescriptor(
            binaryName: "codex",
            overrideEnvVar: "CODEX_CLI_PATH",
            buildCommand: { executable, candidate, bounds in
                CodexWakeCommandBuilder.build(
                    executable: executable,
                    candidate: candidate,
                    account: account,
                    bounds: bounds,
                    prompt: prompt,
                    permissionMode: permissionMode,
                    bypassAcknowledged: bypassAcknowledged,
                    baseEnvironment: baseEnvironment
                )
            },
            classifyDenial: nil
        )
    }
}

nonisolated extension WakeProcessRunner {
    /// Codex runner — same defaults the removed provider-specific runner had.
    static func codex(
        account: CodexAccount,
        executable: String? = nil,
        permissionMode: WakePermissionMode = .safe,
        bypassAcknowledged: Bool = false,
        prompt: String = WakeCommandBuilder.defaultPrompt,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        lockFactory: @escaping @Sendable () -> WakeLock = { WakeLock() },
        lockMode: WakeExecutionLockMode = .acquirePerRun,
        logger: WakeRunLogger = WakeRunLogger(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> WakeProcessRunner {
        WakeProcessRunner(
            descriptor: .codex(
                account: account,
                permissionMode: permissionMode,
                bypassAcknowledged: bypassAcknowledged,
                prompt: prompt,
                baseEnvironment: baseEnvironment
            ),
            executable: executable,
            lockFactory: lockFactory,
            lockMode: lockMode,
            logger: logger,
            now: now
        )
    }
}
