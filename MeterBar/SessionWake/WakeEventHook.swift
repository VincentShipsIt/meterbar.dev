import Darwin
import Foundation

/// The three Session Wake transitions that may invoke a user-configured local command.
nonisolated enum WakeEventHookEvent: String, Codable, CaseIterable, Sendable {
    case quotaExhausted = "quota-exhausted"
    case quotaReset = "quota-reset"
    case wakeComplete = "wake-complete"

    var displayName: String {
        switch self {
        case .quotaExhausted: return "Quota exhausted"
        case .quotaReset: return "Quota reset"
        case .wakeComplete: return "Wake complete"
        }
    }
}

/// Persisted command and per-event opt-ins. Arguments are literal argv entries:
/// no shell parsing, interpolation, placeholder expansion, or environment templates.
nonisolated struct WakeEventHookConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var enabledEvents: Set<WakeEventHookEvent>

    static let disabled = Self(executablePath: "", arguments: [], enabledEvents: [])

    var normalizedExecutablePath: String {
        executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        normalizedExecutablePath.hasPrefix("/")
    }

    func isEnabled(for event: WakeEventHookEvent) -> Bool {
        isConfigured && enabledEvents.contains(event)
    }
}

/// Metadata is passed only through a fixed environment contract. User arguments
/// are never rewritten with event or provider values.
nonisolated struct WakeEventHookContext: Equatable, Sendable {
    let eventName: String
    let provider: WakeProvider?

    static func automatic(_ event: WakeEventHookEvent, provider: WakeProvider) -> Self {
        Self(eventName: event.rawValue, provider: provider)
    }

    static let test = Self(eventName: "test", provider: nil)
}

/// Pure transition tracker shared by the app and launch-agent dispatchers.
///
/// `quotaBlocked` deliberately survives scanning/unknown states and repeated
/// watcher passes, so retries cannot launch duplicate exhausted hooks. A later
/// `.running` transition proves quota became available and emits one reset.
nonisolated struct WakeEventHookTransitionTracker: Sendable {
    private var quotaBlocked = false
    private var wasCompleted = false

    mutating func event(for state: WakeWatcherState) -> WakeEventHookEvent? {
        defer {
            if case .completed = state {
                wasCompleted = true
            } else {
                wasCompleted = false
            }
        }

        switch state {
        case .waiting:
            guard !quotaBlocked else { return nil }
            quotaBlocked = true
            return .quotaExhausted
        case .running:
            guard quotaBlocked else { return nil }
            quotaBlocked = false
            return .quotaReset
        case let .completed(summary):
            guard !wasCompleted, summary.attempted > 0 || summary.remaining > 0 else { return nil }
            quotaBlocked = false
            return .wakeComplete
        case .off:
            return nil
        case .idle, .scanning, .quotaUnknown, .stopping, .failed:
            return nil
        }
    }
}

/// Result from one bounded direct-`Process` invocation. Captured bytes are kept
/// only in memory for focused verification and are never written to diagnostics.
nonisolated struct WakeEventHookResult: Sendable {
    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case launchFailed(String)
    }

    let termination: Termination
    let stdoutByteCount: Int
    let stderrByteCount: Int
    let stdoutCapture: Data
    let stderrCapture: Data

    var succeeded: Bool {
        termination == .exited(0)
    }

    var userMessage: String {
        switch termination {
        case .exited(0): return "Hook completed successfully."
        case let .exited(code): return "Hook exited with status \(code)."
        case .timedOut: return "Hook timed out."
        case let .launchFailed(reason): return reason
        }
    }
}

/// Launches one hook with Foundation `Process` directly. Output is drained
/// concurrently and retained only up to `maxCaptureBytes`; runtime is bounded
/// by `timeout`, and timeout escalation terminates then kills the child.
nonisolated struct WakeEventHookRunner: Sendable {
    private let timeout: TimeInterval
    private let maxCaptureBytes: Int
    private let logger: WakeRunLogger
    private let now: @Sendable () -> Date

    init(
        timeout: TimeInterval = 10,
        maxCaptureBytes: Int = 16 * 1024,
        logger: WakeRunLogger = WakeRunLogger(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeout = max(0.01, timeout)
        self.maxCaptureBytes = max(0, maxCaptureBytes)
        self.logger = logger
        self.now = now
    }

    func run(
        configuration: WakeEventHookConfiguration,
        context: WakeEventHookContext
    ) async -> WakeEventHookResult {
        let start = now()
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(configuration: configuration, context: context))
            }
        }
        record(result, context: context, start: start)
        return result
    }

    private func runBlocking(
        configuration: WakeEventHookConfiguration,
        context: WakeEventHookContext
    ) -> WakeEventHookResult {
        let executable = configuration.normalizedExecutablePath
        guard !executable.isEmpty else {
            return emptyResult(.launchFailed("Configure an executable before testing the hook."))
        }
        guard executable.hasPrefix("/") else {
            return emptyResult(.launchFailed("The configured executable path must be absolute."))
        }
        guard FileManager.default.fileExists(atPath: executable) else {
            return emptyResult(.launchFailed("The configured executable does not exist."))
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return emptyResult(.launchFailed("The configured file is not executable."))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: ServiceSupport.realHomeDirectory(),
            isDirectory: true
        )
        let parentEnvironment = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": ServiceSupport.realHomeDirectory(),
            "PATH": CLIBinaryLocator.augmentedPATH(environment: parentEnvironment),
            "TMPDIR": parentEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": parentEnvironment["LANG"] ?? "en_US.UTF-8",
            "NO_COLOR": "1"
        ]
        environment["METERBAR_WAKE_EVENT"] = context.eventName
        environment["METERBAR_WAKE_PROVIDER"] = context.provider?.rawValue ?? "test"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            close(pipe: stdoutPipe)
            close(pipe: stderrPipe)
            return emptyResult(.launchFailed("The configured executable could not be launched."))
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let stdout = BoundedCapture(limit: maxCaptureBytes)
        let stderr = BoundedCapture(limit: maxCaptureBytes)
        let drains = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdout, group: drains)
        drain(stderrPipe.fileHandleForReading, into: stderr, group: drains)

        let didTimeOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if didTimeOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        if drains.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        return WakeEventHookResult(
            termination: didTimeOut ? .timedOut : .exited(process.terminationStatus),
            stdoutByteCount: stdout.byteCount,
            stderrByteCount: stderr.byteCount,
            stdoutCapture: stdout.data,
            stderrCapture: stderr.data
        )
    }

    private func record(_ result: WakeEventHookResult, context: WakeEventHookContext, start: Date) {
        let outcome: String
        let exitCode: Int32?
        switch result.termination {
        case .exited(0):
            outcome = "succeeded"
            exitCode = 0
        case let .exited(code):
            outcome = "failed"
            exitCode = code
        case .timedOut:
            outcome = "timed-out"
            exitCode = nil
        case .launchFailed:
            outcome = "launch-failed"
            exitCode = nil
        }
        logger.append(WakeRunLogger.Record(
            timestamp: start,
            event: "hook",
            sessionID: context.provider?.rawValue ?? "test",
            reason: context.eventName,
            outcome: outcome,
            exitCode: exitCode,
            durationMilliseconds: Int(now().timeIntervalSince(start) * 1000),
            stdoutBytes: result.stdoutByteCount,
            stderrBytes: result.stderrByteCount
        ))
    }

    private func emptyResult(_ termination: WakeEventHookResult.Termination) -> WakeEventHookResult {
        WakeEventHookResult(
            termination: termination,
            stdoutByteCount: 0,
            stderrByteCount: 0,
            stdoutCapture: Data(),
            stderrCapture: Data()
        )
    }

    private func close(pipe: Pipe) {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    private func drain(
        _ handle: FileHandle,
        into capture: BoundedCapture,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 8 * 1024),
                          !chunk.isEmpty else { return }
                    capture.append(chunk)
                } catch {
                    return
                }
            }
        }
    }
}

/// Thread-safe bridge from synchronous watcher state callbacks to a serial
/// async hook queue. Hook failures are intentionally discarded here: the runner
/// records bounded metadata and never changes watcher state.
nonisolated final class WakeEventHookDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let runner: WakeEventHookRunner
    private var configuration: WakeEventHookConfiguration
    private var tracker = WakeEventHookTransitionTracker()
    private var pending: Task<Void, Never>?

    init(
        configuration: WakeEventHookConfiguration = .disabled,
        runner: WakeEventHookRunner = WakeEventHookRunner()
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    func update(configuration: WakeEventHookConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func observe(_ state: WakeWatcherState, provider: WakeProvider) {
        lock.lock()
        guard let event = tracker.event(for: state),
              configuration.isEnabled(for: event) else {
            lock.unlock()
            return
        }
        let command = configuration
        let previous = pending
        let runner = self.runner
        let context = WakeEventHookContext.automatic(event, provider: provider)
        let task = Task.detached(priority: .utility) {
            await previous?.value
            _ = await runner.run(configuration: command, context: context)
        }
        pending = task
        lock.unlock()
    }
}

nonisolated private final class BoundedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var total = 0
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        total += chunk.count
        let remaining = limit - storage.count
        if remaining > 0 {
            storage.append(contentsOf: chunk.prefix(remaining))
        }
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
