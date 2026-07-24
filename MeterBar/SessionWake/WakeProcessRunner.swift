import Foundation

/// Whether the runner takes the shared Session Wake lock itself or runs under
/// a process-lifetime lock already held by the continuous app/agent watcher.
nonisolated enum WakeExecutionLockMode: Equatable, Sendable {
    case acquirePerRun
    case externallyOwned
}

/// The per-provider axes a Session Wake process run differs along. Everything
/// else (revalidate cwd, take the lock, spawn with an argv, enforce timeout,
/// honor cancellation, record a metadata-only log line) is identical across
/// providers and lives in `WakeProcessRunner`.
nonisolated struct WakeRunnerDescriptor: Sendable {
    /// CLI binary to resolve/spawn; also used verbatim in outcome messages.
    let binaryName: String
    /// Env var that overrides binary resolution (e.g. `CLAUDE_CLI_PATH`).
    let overrideEnvVar: String
    /// Builds the argv+env+cwd for one resume. Captures the bound account,
    /// permission mode, bypass ack, prompt, and base environment.
    let buildCommand: @Sendable (
        _ executable: String,
        _ candidate: WakeSessionCandidate,
        _ bounds: WakeBounds
    ) -> WakeCommand
    /// Optional denial classifier for a non-zero exit. `nil` ⇒ a non-zero exit
    /// is always a plain failure (Codex: `approval_policy=never` can't stop at a
    /// permission gate, so there is nothing to classify).
    let classifyDenial: (@Sendable (ManagedProcess.Result) -> Bool)?
}

/// The one native process runner shared by MeterBar and its CLI.
///
/// Responsibilities: revalidate the target immediately before exec, take the
/// shared lock only when actually ready to run, spawn the provider CLI with an
/// argument array (never a shell), enforce a timeout with process-tree cleanup,
/// honor structured-task cancellation, and record a metadata-only log line. A
/// dead worktree is a structured skip, not a failure that aborts the queue.
nonisolated struct WakeProcessRunner: WakeExecuting {
    /// Explicit executable path; when nil the descriptor's binary is resolved.
    let executable: String?
    private let descriptor: WakeRunnerDescriptor
    private let lockFactory: @Sendable () -> WakeLock
    private let lockMode: WakeExecutionLockMode
    private let logger: WakeRunLogger
    private let now: @Sendable () -> Date

    init(
        descriptor: WakeRunnerDescriptor,
        executable: String? = nil,
        lockFactory: @escaping @Sendable () -> WakeLock = { WakeLock() },
        lockMode: WakeExecutionLockMode = .acquirePerRun,
        logger: WakeRunLogger = WakeRunLogger(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.descriptor = descriptor
        self.executable = executable
        self.lockFactory = lockFactory
        self.lockMode = lockMode
        self.logger = logger
        self.now = now
    }

    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        // Revalidate cwd immediately before exec — a worktree deleted since
        // discovery is a skip, and the queue keeps going.
        guard let cwd = candidate.workingDirectory, isDirectory(cwd) else {
            record(candidate: candidate, outcome: .skipped(reason: .missingWorkingDirectory), result: nil, start: now())
            return .skipped(reason: .missingWorkingDirectory)
        }

        let path = executable ?? CLIBinaryLocator.resolve(
            command: descriptor.binaryName,
            overrideEnvVar: descriptor.overrideEnvVar
        )
        guard let resolved = path else {
            let outcome = WakeRunOutcome.failed(reason: "\(descriptor.binaryName) binary not found")
            record(candidate: candidate, outcome: outcome, result: nil, start: now())
            return outcome
        }

        let lock = lockMode == .acquirePerRun ? lockFactory() : nil
        if let lock {
            // One-shot CLI runs take the shared lock only when ready to launch.
            // Continuous app/agent watchers pass `.externallyOwned` because they
            // hold the same lock for their whole lifetime.
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

        let command = descriptor.buildCommand(resolved, candidate, bounds)
        // Overwrite the resolved cwd with the just-revalidated one.
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

        let outcome = Self.mapOutcome(result, descriptor: descriptor)
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

    static func mapOutcome(_ result: ManagedProcess.Result, descriptor: WakeRunnerDescriptor) -> WakeRunOutcome {
        switch result.termination {
        case .exited(0):
            return .succeeded
        case let .exited(code):
            // Classification only — the bounded capture is inspected here and never
            // logged or retained beyond this call.
            if descriptor.classifyDenial?(result) == true {
                return .permissionDenied
            }
            return .failed(reason: "\(descriptor.binaryName) exited with status \(code)")
        case let .signalled(signal):
            return .failed(reason: "\(descriptor.binaryName) terminated by signal \(signal)")
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

nonisolated extension WakeRunnerDescriptor {
    /// Descriptor for a Claude Code resume.
    static func claude(
        account: ClaudeCodeAccount,
        permissionMode: WakePermissionMode,
        bypassAcknowledged: Bool,
        prompt: String,
        baseEnvironment: [String: String]
    ) -> WakeRunnerDescriptor {
        WakeRunnerDescriptor(
            binaryName: "claude",
            overrideEnvVar: "CLAUDE_CLI_PATH",
            buildCommand: { executable, candidate, bounds in
                WakeCommandBuilder.build(
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
            classifyDenial: { result in
                // BUG-FOR-BUG PRESERVATION: the original gate keyed off the RAW
                // requested `permissionMode` (NOT the effective/acknowledged
                // mode). A bypass request skips the permission gate entirely, so
                // a denial label can't apply there. Keep this exact check.
                guard permissionMode != .bypass else { return false }
                // Lossy decode: a capture truncated at the byte cap can split a
                // multibyte character; strict decoding would drop the WHOLE
                // capture and disable classification in exactly the long-output
                // case the bounded sink exists for.
                // swiftlint:disable optional_data_string_conversion
                let combined = String(decoding: result.stdoutCapture, as: UTF8.self)
                    + "\n"
                    + String(decoding: result.stderrCapture, as: UTF8.self)
                // swiftlint:enable optional_data_string_conversion
                return PermissionDenialDetector.indicatesDenial(in: combined)
            }
        )
    }
}

nonisolated extension WakeProcessRunner {
    /// Claude Code runner — same defaults the old `WakeProcessRunner.init` had.
    static func claude(
        account: ClaudeCodeAccount,
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
            descriptor: .claude(
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

nonisolated extension WakeRunOutcome {
    /// Stable label for structured logs (never includes content).
    var logLabel: String {
        switch self {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .cancelled: return "cancelled"
        case .permissionDenied: return "permission-denied"
        }
    }
}
