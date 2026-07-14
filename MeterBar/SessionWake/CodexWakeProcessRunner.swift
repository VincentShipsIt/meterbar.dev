import Foundation

/// The native process runner for Codex resumes — the Codex sibling of
/// `WakeProcessRunner`.
///
/// Same discipline: revalidate the target cwd immediately before exec, take the
/// shared lock only when actually ready, spawn `codex` with an argument array
/// (never a shell), enforce a timeout with process-tree cleanup, honor
/// structured cancellation, and record a metadata-only log line. Codex `.safe`
/// runs cannot escalate (approval_policy=never), so a non-zero exit is a plain
/// failure — there is no permission-denial gate to classify as with Claude.
nonisolated struct CodexWakeProcessRunner: WakeExecuting {
    /// Explicit executable path; when nil the `codex` binary is resolved.
    let executable: String?
    let permissionMode: WakePermissionMode
    let bypassAcknowledged: Bool
    let prompt: String
    let account: CodexAccount
    private let baseEnvironment: [String: String]
    private let lockFactory: @Sendable () -> WakeLock
    private let lockMode: WakeExecutionLockMode
    private let logger: WakeRunLogger
    private let now: @Sendable () -> Date

    init(
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
    ) {
        self.account = account
        self.executable = executable
        self.permissionMode = permissionMode
        self.bypassAcknowledged = bypassAcknowledged
        self.prompt = prompt
        self.baseEnvironment = baseEnvironment
        self.lockFactory = lockFactory
        self.lockMode = lockMode
        self.logger = logger
        self.now = now
    }

    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        guard let cwd = candidate.workingDirectory, isDirectory(cwd) else {
            record(candidate: candidate, outcome: .skipped(reason: .missingWorkingDirectory), result: nil, start: now())
            return .skipped(reason: .missingWorkingDirectory)
        }

        let codexPath = executable ?? CLIBinaryLocator.resolve(command: "codex", overrideEnvVar: "CODEX_CLI_PATH")
        guard let resolved = codexPath else {
            record(candidate: candidate, outcome: .failed(reason: "codex binary not found"), result: nil, start: now())
            return .failed(reason: "codex binary not found")
        }

        let lock = lockMode == .acquirePerRun ? lockFactory() : nil
        if let lock {
            switch lock.acquire() {
            case .acquired:
                break
            case let .contended(holder):
                let suffix = holder.map { " (\($0.shortDescription))" } ?? ""
                let outcome = WakeRunOutcome.failed(reason: "another Session Wake holder is active\(suffix)")
                record(candidate: candidate, outcome: outcome, result: nil, start: now())
                return outcome
            case let .legacyHeld(guidance):
                let outcome = WakeRunOutcome.failed(reason: guidance)
                record(candidate: candidate, outcome: outcome, result: nil, start: now())
                return outcome
            case let .unavailable(reason):
                let outcome = WakeRunOutcome.failed(reason: "wake lock unavailable: \(reason)")
                record(candidate: candidate, outcome: outcome, result: nil, start: now())
                return outcome
            }
        }
        defer { lock?.release() }

        let command = CodexWakeCommandBuilder.build(
            executable: resolved,
            candidate: candidate,
            account: account,
            bounds: bounds,
            prompt: prompt,
            permissionMode: permissionMode,
            bypassAcknowledged: bypassAcknowledged,
            baseEnvironment: baseEnvironment
        )
        let validated = WakeCommand(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: cwd
        )

        let start = now()
        let cancellation = ManagedProcess.Cancellation()
        let result = await withTaskCancellationHandler {
            await spawn(validated, timeout: bounds.perSessionTimeout, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }

        let outcome = Self.mapOutcome(result)
        record(candidate: candidate, outcome: outcome, result: result, start: start)
        return outcome
    }

    // MARK: - Helpers

    private func spawn(
        _ command: WakeCommand,
        timeout: TimeInterval,
        cancellation: ManagedProcess.Cancellation
    ) async -> ManagedProcess.Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ManagedProcess.run(
                    executable: command.executable,
                    arguments: command.arguments,
                    environment: command.environment,
                    workingDirectory: command.workingDirectory,
                    timeout: timeout,
                    cancellation: cancellation
                )
                continuation.resume(returning: result)
            }
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func mapOutcome(_ result: ManagedProcess.Result) -> WakeRunOutcome {
        switch result.termination {
        case .exited(0):
            return .succeeded
        case let .exited(code):
            return .failed(reason: "codex exited with status \(code)")
        case let .signalled(signal):
            return .failed(reason: "codex terminated by signal \(signal)")
        case .timedOut:
            return .failed(reason: "session timed out")
        case .cancelled:
            return .cancelled
        case let .launchFailed(message):
            return .failed(reason: message)
        }
    }

    private func record(
        candidate: WakeSessionCandidate,
        outcome: WakeRunOutcome,
        result: ManagedProcess.Result?,
        start: Date
    ) {
        let exitCode: Int32?
        switch result?.termination {
        case let .exited(code): exitCode = code
        default: exitCode = nil
        }
        logger.append(WakeRunLogger.Record(
            timestamp: start,
            event: "resume",
            sessionID: candidate.sessionID,
            reason: candidate.reason.rawValue,
            outcome: outcome.logLabel,
            exitCode: exitCode,
            durationMilliseconds: Int(now().timeIntervalSince(start) * 1000),
            stdoutBytes: result?.stdoutByteCount,
            stderrBytes: result?.stderrByteCount
        ))
    }
}
