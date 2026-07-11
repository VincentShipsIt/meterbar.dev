import Foundation

/// The one native process runner shared by MeterBar and its CLI.
///
/// Responsibilities: revalidate the target immediately before exec, take the
/// shared lock only when actually ready to run, spawn `claude` with an argument
/// array (never a shell), enforce a timeout with process-tree cleanup, honor
/// structured-task cancellation, and record a metadata-only log line. A dead
/// worktree is a structured skip, not a failure that aborts the queue.
nonisolated struct WakeProcessRunner: WakeExecuting {
    /// Explicit executable path; when nil the `claude` binary is resolved.
    let executable: String?
    let permissionMode: WakePermissionMode
    let bypassAcknowledged: Bool
    let prompt: String
    let account: ClaudeCodeAccount
    private let baseEnvironment: [String: String]
    private let lockFactory: @Sendable () -> WakeLock
    /// True when the caller (the CLI engine) already holds the shared wake
    /// lock for the whole pass. flock treats a second descriptor in the SAME
    /// process as a distinct holder, so re-acquiring here would self-contend
    /// and fail every real CLI resume — skip locking entirely instead.
    private let assumesExternalLock: Bool
    private let logger: WakeRunLogger
    private let now: @Sendable () -> Date

    init(
        account: ClaudeCodeAccount,
        executable: String? = nil,
        permissionMode: WakePermissionMode = .safe,
        bypassAcknowledged: Bool = false,
        prompt: String = WakeCommandBuilder.defaultPrompt,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        lockFactory: @escaping @Sendable () -> WakeLock = { WakeLock() },
        assumesExternalLock: Bool = false,
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
        self.assumesExternalLock = assumesExternalLock
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

        let claudePath = executable ?? CLIBinaryLocator.resolve(command: "claude", overrideEnvVar: "CLAUDE_CLI_PATH")
        guard let resolved = claudePath else {
            record(candidate: candidate, outcome: .failed(reason: "claude binary not found"), result: nil, start: now())
            return .failed(reason: "claude binary not found")
        }

        // Take the shared lock only now, when we are actually ready to launch
        // — unless the caller already holds it for the whole pass.
        let lock = assumesExternalLock ? nil : lockFactory()
        switch lock?.acquire() ?? .acquired {
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
        defer { lock?.release() }

        let command = WakeCommandBuilder.build(
            executable: resolved,
            candidate: candidate,
            account: account,
            bounds: bounds,
            prompt: prompt,
            permissionMode: permissionMode,
            bypassAcknowledged: bypassAcknowledged,
            baseEnvironment: baseEnvironment
        )
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

        let outcome = Self.mapOutcome(result, permissionMode: permissionMode)
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

    static func mapOutcome(_ result: ManagedProcess.Result, permissionMode: WakePermissionMode) -> WakeRunOutcome {
        switch result.termination {
        case .exited(0):
            return .succeeded
        case let .exited(code):
            // Classification only — the bounded capture is inspected here and
            // never logged or retained beyond this call. Bypass runs skip the
            // permission gate entirely, so a denial label can't apply there.
            if permissionMode != .bypass, indicatesPermissionDenial(result) {
                return .permissionDenied
            }
            return .failed(reason: "claude exited with status \(code)")
        case let .signalled(signal):
            return .failed(reason: "claude terminated by signal \(signal)")
        case .timedOut:
            return .failed(reason: "session timed out")
        case .cancelled:
            return .cancelled
        case let .launchFailed(message):
            return .failed(reason: message)
        }
    }

    /// Whether a non-zero exit reads as a stop at the permission-approval gate.
    /// The captured output exists only in memory on `result`; nothing here (or
    /// downstream) writes it anywhere.
    private static func indicatesPermissionDenial(_ result: ManagedProcess.Result) -> Bool {
        // Lossy decode: a capture truncated at the byte cap can split a
        // multibyte character, and strict decoding would drop the WHOLE
        // capture — disabling classification in exactly the long-output case
        // the bounded sink exists for.
        // swiftlint:disable optional_data_string_conversion
        let combined = String(decoding: result.stdoutCapture, as: UTF8.self)
            + "\n"
            + String(decoding: result.stderrCapture, as: UTF8.self)
        // swiftlint:enable optional_data_string_conversion
        return PermissionDenialDetector.indicatesDenial(in: combined)
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
