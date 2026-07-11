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

        var isSuccess: Bool {
            if case .exited(0) = termination { return true }
            return false
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

        fileprivate static func killGroup(_ pgid: pid_t) {
            // Negative pid targets the whole process group.
            _ = kill(-pgid, SIGKILL)
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
            return Result(termination: .launchFailed("pipe() failed"), stdoutByteCount: 0, stderrByteCount: 0)
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
        // New process group with the child as leader ⇒ kill(-pgid) hits the tree.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

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
            return Result(
                termination: .launchFailed("posix_spawn failed (\(spawnResult))"),
                stdoutByteCount: 0,
                stderrByteCount: 0
            )
        }

        cancellation.attach(pgid: pid)

        let outCounter = drain(fd: outPipe[0], cap: maxCaptureBytes)
        let errCounter = drain(fd: errPipe[0], cap: maxCaptureBytes)

        let termination = wait(pid: pid, timeout: timeout, cancellation: cancellation)

        // Ensure drains finish and fds close.
        let outBytes = outCounter.wait()
        let errBytes = errCounter.wait()

        return Result(termination: termination, stdoutByteCount: outBytes, stderrByteCount: errBytes)
    }

    // MARK: - Draining

    private final class DrainHandle: @unchecked Sendable {
        private let queue: DispatchQueue
        private var bytes = 0
        private let group = DispatchGroup()

        init(fd: Int32, cap: Int) {
            queue = DispatchQueue(label: "dev.meterbar.app.wake.drain.\(fd)")
            group.enter()
            queue.async { [self] in
                defer { close(fd); self.group.leave() }
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    // Count everything, but only the cap bounds memory pressure.
                    bytes += n
                    if bytes > cap { /* keep reading to drain, discard content */ }
                }
            }
        }

        func wait() -> Int {
            group.wait()
            return bytes
        }
    }

    private static func drain(fd: Int32, cap: Int) -> DrainHandle {
        DrainHandle(fd: fd, cap: cap)
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
                Cancellation.killGroup(pid)
                _ = waitpid(pid, &status, 0)
                return .timedOut
            }
            usleep(20_000) // 20ms poll
        }
    }

    private static func _WSTATUS(_ status: Int32) -> Int32 { status & 0x7F }
}
