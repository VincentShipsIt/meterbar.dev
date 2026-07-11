import Darwin
import Foundation

/// A `posix_spawn`-based child launcher with a private process group, concurrent
/// bounded stdout/stderr draining, a hard timeout, and process-tree cleanup.
///
/// Foundation's `Process` reads pipes only after the child exits and offers no
/// process-group control, which both deadlocks on large output and leaks
/// grandchildren on timeout. This launcher spawns the child as its own group
/// leader so cancellation or timeout can `kill(-pgid)` the whole tree, and
/// drains both pipes on background queues with a byte cap so a chatty child can
/// never fill a pipe buffer and hang.
nonisolated enum ManagedProcess {
    /// How long to wait for the pipe drains to finish after the child is reaped
    /// before force-killing the group to unstick an inherited-fd hang.
    private static let drainGrace: TimeInterval = 2
    /// How long a timed-out child is given to exit on `SIGTERM` before `SIGKILL`.
    private static let terminationGrace: TimeInterval = 2

    struct Result: Sendable {
        enum Termination: Equatable, Sendable {
            case exited(code: Int32)
            case signalled(signal: Int32)
            case timedOut
            case cancelled
            case launchFailed(String)
        }
        let termination: Termination
        /// Bounded stdout capture (diagnostic only; never persisted verbatim).
        let stdoutByteCount: Int
        let stderrByteCount: Int
        /// Whether the stream exceeded `maxCaptureBytes` (content past the cap is
        /// counted but discarded, so a caller knows the capture is incomplete).
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        /// The leading `maxCaptureBytes` of each stream, retained in memory for
        /// the caller to *classify* the run (e.g. permission-denial detection).
        /// PRIVACY: this content must never be written to logs or persisted —
        /// only metadata (byte counts, truncation flags, outcome labels) may be
        /// recorded. It lives exactly as long as this `Result` value.
        let stdoutCapture: Data
        let stderrCapture: Data

        var isSuccess: Bool {
            if case .exited(0) = termination { return true }
            return false
        }

        /// A content-free result for failures before any stream existed.
        fileprivate static func empty(_ termination: Termination) -> Result {
            Result(
                termination: termination,
                stdoutByteCount: 0,
                stderrByteCount: 0,
                stdoutTruncated: false,
                stderrTruncated: false,
                stdoutCapture: Data(),
                stderrCapture: Data()
            )
        }
    }

    /// Cooperative cancellation handle handed to callers before launch.
    ///
    /// A cancel that arrives before the child is attached is remembered and the
    /// group is killed the instant it is; a cancel after attach kills the group
    /// immediately. Either way `wasCancelled()` lets the waiter report
    /// `.cancelled` rather than a bare `SIGKILL` signal.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var pgid: pid_t?
        private var cancelled = false

        func attach(pgid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            if cancelled {
                Cancellation.killGroup(pgid)
                return
            }
            self.pgid = pgid
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let pgid { Cancellation.killGroup(pgid) }
        }

        func wasCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        fileprivate static func killGroup(_ pgid: pid_t, signal: Int32 = SIGKILL) {
            // Negative pid targets the whole process group.
            _ = kill(-pgid, signal)
        }
    }

    /// Launch `executable` with `arguments` in `workingDirectory`, capping each
    /// captured stream at `maxCaptureBytes` and killing the tree after
    /// `timeout` seconds.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        timeout: TimeInterval,
        maxCaptureBytes: Int = 64 * 1024,
        cancellation: Cancellation = Cancellation()
    ) -> Result {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let outPipe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        let errPipe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { outPipe.deallocate(); errPipe.deallocate() }
        guard pipe(outPipe) == 0, pipe(errPipe) == 0 else {
            return .empty(.launchFailed("pipe() failed"))
        }

        // Child: stdin from /dev/null, stdout/stderr to the pipe write ends.
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Reset the child's signal state to a clean default. We spawn from a
        // libdispatch worker thread, whose signal mask may block signals such as
        // SIGTERM; without this the child would inherit that blocked mask and be
        // unable to receive the graceful SIGTERM we send on timeout (only the
        // unblockable SIGKILL would get through). Empty the mask and restore
        // every disposition to SIG_DFL so the child behaves like a normal process.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        // New process group with the child as leader ⇒ kill(-pgid) hits the tree.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        // Parent closes the write ends so read EOFs when the child exits.
        close(outPipe[1]); close(errPipe[1])
        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return .empty(.launchFailed("posix_spawn failed (\(spawnResult))"))
        }

        cancellation.attach(pgid: pid)

        let outSink = BoundedSink(cap: maxCaptureBytes)
        let errSink = BoundedSink(cap: maxCaptureBytes)
        let drains = DispatchGroup()
        drain(fd: outPipe[0], into: outSink, group: drains)
        drain(fd: errPipe[0], into: errSink, group: drains)

        let termination = wait(pid: pid, timeout: timeout, cancellation: cancellation)

        // Drain-hang protection. The main child is reaped, but a backgrounded
        // grandchild that inherited a pipe's write end keeps it open, so the drain
        // reads never observe EOF and an unconditional wait would block forever.
        // Wait only a bounded grace; if the drains have not finished, SIGKILL the
        // whole group to force the inherited fds closed, then wait for the drains.
        if drains.wait(timeout: .now() + drainGrace) == .timedOut {
            Cancellation.killGroup(pid, signal: SIGKILL)
            // The group kill can't reach a descendant that re-sessioned via
            // setsid(); if it still holds a write end, bound this wait too and
            // return with the bytes counted so far — one leaked drain block is
            // better than run() never returning.
            _ = drains.wait(timeout: .now() + drainGrace)
        }

        return Result(
            termination: termination,
            stdoutByteCount: outSink.count,
            stderrByteCount: errSink.count,
            stdoutTruncated: outSink.truncated,
            stderrTruncated: errSink.truncated,
            stdoutCapture: outSink.capturedData,
            stderrCapture: errSink.capturedData
        )
    }

    // MARK: - Draining

    /// Thread-safe bounded collector for one drained stream. Every byte read is
    /// counted so the caller learns the true stream size, but only the leading
    /// `cap` bytes are retained — the buffer can never grow past the cap, so a
    /// runaway child cannot exhaust memory. Draining always continues past the
    /// cap (excess is counted and discarded, never blocking the pipe).
    private final class BoundedSink: @unchecked Sendable {
        private let lock = NSLock()
        private let cap: Int
        private var total = 0
        private var storage = Data()

        init(cap: Int) { self.cap = max(0, cap) }

        func append(_ buffer: [UInt8], count: Int) {
            lock.lock(); defer { lock.unlock() }
            total += count
            let remaining = cap - storage.count
            guard remaining > 0 else { return }
            storage.append(contentsOf: buffer[0..<min(remaining, count)])
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return total
        }

        var truncated: Bool {
            lock.lock(); defer { lock.unlock() }
            return total > storage.count
        }

        var capturedData: Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private static func drain(fd: Int32, into sink: BoundedSink, group: DispatchGroup) {
        let queue = DispatchQueue(label: "dev.meterbar.app.wake.drain.\(fd)")
        group.enter()
        queue.async {
            defer { close(fd); group.leave() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    // Retain up to the cap; count everything past it.
                    sink.append(buffer, count: n)
                } else if n == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    // MARK: - Waiting

    private static func wait(pid: pid_t, timeout: TimeInterval, cancellation: Cancellation) -> Result.Termination {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                if cancellation.wasCancelled() { return .cancelled }
                if _WSTATUS(status) == 0 {
                    return .exited(code: (status >> 8) & 0xFF)
                }
                return .signalled(signal: _WSTATUS(status))
            }
            if result == -1 {
                return .launchFailed("waitpid failed")
            }
            if Date() >= deadline {
                escalateTimeout(pid: pid)
                return .timedOut
            }
            usleep(20_000) // 20ms poll
        }
    }

    /// Graceful timeout escalation: first `SIGTERM` the process group so a
    /// well-behaved child can flush and exit, wait a bounded grace for it to
    /// reap, then `SIGKILL` the group and block until it is gone. Going straight
    /// to `SIGKILL` would deny the child any chance to clean up.
    private static func escalateTimeout(pid: pid_t) {
        Cancellation.killGroup(pid, signal: SIGTERM)
        let graceDeadline = Date().addingTimeInterval(terminationGrace)
        var status: Int32 = 0
        var reaped = false
        while Date() < graceDeadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                break
            }
            usleep(20_000)
        }
        // SIGKILL the group even when the leader reaped within the grace: a
        // grandchild that traps SIGTERM would otherwise outlive the timeout,
        // losing the class's tree-cleanup guarantee. While any group member
        // survives, POSIX forbids recycling the pid as another group's pgid,
        // so this cannot target an unrelated tree; on an empty group it is a
        // harmless ESRCH.
        Cancellation.killGroup(pid, signal: SIGKILL)
        if !reaped {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {
                continue
            }
        }
    }

    private static func _WSTATUS(_ status: Int32) -> Int32 { status & 0x7F }
}
