import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MeterBar

/// `meterbar wake` — a thin wrapper over the same native engine the app uses to
/// resume Claude Code sessions blocked on usage limits.
///
/// Design contract (#99):
/// - `--dry-run` performs no subprocess and no mutation.
/// - With `--json`, stdout carries only the versioned response; diagnostics go
///   to stderr.
/// - Outcomes (blocked-without-wait, quota-unknown, validation failure, partial
///   failure, cancellation, success) are distinguishable via the exit code.
/// - SIGINT releases the shared lock and leaves no child process.
/// - Configuration comes from explicit flags or the shared app-group domain,
///   never the CLI process's own `UserDefaults.standard`.
/// - Both `claude` and `codex` providers are supported; each resumes only its
///   own blocked sessions, gated by that account's fresh usage quota.
struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resume Claude Code or Codex sessions blocked on usage limits"
    )

    @Flag(name: .long, help: "Preview resumable sessions without launching anything.")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Emit only the versioned JSON response on stdout.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Provider: 'claude' (default) or 'codex'.")
    var provider: String = "claude"

    @Option(name: .long, help: "Explicit config dir for the wake account (CLAUDE_CONFIG_DIR for claude, CODEX_HOME for codex).")
    var configDir: String?

    @Option(name: .shortAndLong, help: "Maximum sessions to resume this run.")
    var limit: Int?

    @Option(name: .long, help: "Permission posture: safe (default) or bypass.")
    var permissionMode: String = "safe"

    @Flag(name: .long, help: "Acknowledge permission-bypass mode (required for --permission-mode bypass).")
    var yesBypass: Bool = false

    func run() async throws {
        let cancelBox = CancelBox()
        let signalSource = installSignalHandler(cancelBox)
        defer { signalSource.cancel() }

        let request = SessionWakeCLI.Request(
            provider: provider,
            configDirectory: configDir,
            dryRun: dryRun,
            limit: limit,
            permissionMode: permissionMode,
            bypassAcknowledged: yesBypass,
            shouldCancel: { cancelBox.isCancelled }
        )
        // Await directly instead of parking the main thread on a semaphore:
        // under MainActor default isolation the engine's jobs need the main
        // thread, so a blocked main thread deadlocks `meterbar wake`.
        let result = await SessionWakeCLI.run(request)

        emit(result)
        throw ExitCode(result.exitCode)
    }

    private func emit(_ result: SessionWakeCLI.Result) {
        if json {
            print(result.jsonOutput) // stdout: JSON only
            return
        }
        print(result.summaryLine)
        if let message = result.message {
            var stderr = StandardError()
            Swift.print(message, to: &stderr)
        }
    }

    private func installSignalHandler(_ box: CancelBox) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { box.cancel() }
        source.resume()
        return source
    }
}

/// Thread-safe cancellation flag toggled by the SIGINT handler.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Minimal stderr text stream so diagnostics never contaminate JSON stdout.
private struct StandardError: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
