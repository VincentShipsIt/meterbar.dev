import Darwin
import Foundation

/// Line-oriented buffer for an agent's stdout, filled by a background drain and
/// consumed by the request/response loop.
///
/// Bounded on purpose: a chatty or looping agent must never be able to grow this
/// without limit. Once the cap is passed the buffer stops accumulating, records
/// the overflow, and closes itself so the waiting reader fails fast with an
/// honest "unreadable response" instead of consuming memory forever.
nonisolated final class GrokLineBuffer: @unchecked Sendable {
    /// Generous next to a billing response (a few KB) and still far below
    /// anything that could pressure memory.
    static let maxBufferedBytes = 512 * 1024

    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [Data] = []
    private var bufferedBytes = 0
    private var finished = false
    private var overflowed = false

    var hasFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    var didOverflow: Bool {
        condition.lock(); defer { condition.unlock() }
        return overflowed
    }

    func append(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard !finished else { return }

        bufferedBytes += data.count
        guard bufferedBytes <= Self.maxBufferedBytes else {
            overflowed = true
            finished = true
            pending.removeAll(keepingCapacity: false)
            return
        }

        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[..<newline]))
            pending.removeSubrange(...newline)
        }
    }

    /// Marks the end of the stream, flushing any trailing bytes the agent wrote
    /// without a final newline (a truncated frame) as one last line.
    func finish() {
        condition.lock()
        if !pending.isEmpty {
            lines.append(pending)
            pending.removeAll(keepingCapacity: false)
        }
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func nextLine(until deadline: Date) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty, !finished, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }
}

/// A supervised, bidirectional child process for the Grok Build ACP agent.
///
/// `ManagedProcess` is the repo's launcher for one-shot commands, but it wires
/// stdin to `/dev/null` and only returns once the child is gone — ACP needs a
/// live stdin to write requests to while reading responses back. This class
/// keeps `ManagedProcess`'s guarantees for that bidirectional case: the child is
/// spawned as its own process-group leader so cleanup can `kill(-pgid)` the
/// whole tree, both output streams drain concurrently so a full pipe buffer can
/// never deadlock the agent, and termination escalates `SIGTERM` → grace →
/// `SIGKILL` so no `grok` process outlives the request that started it.
///
/// Every live instance is registered, so app termination can reap agents that a
/// request never got to clean up itself.
nonisolated final class GrokAgentProcess: @unchecked Sendable {
    enum Error: Swift.Error {
        case launchFailed
        case writeFailed
    }

    /// How long a terminating agent is given to exit on `SIGTERM` before `SIGKILL`.
    private static let terminationGrace: TimeInterval = 1
    /// How long to wait for the drains to observe EOF after the child is reaped.
    private static let drainGrace: TimeInterval = 1

    /// Stdout, split into JSON-RPC frames.
    let lines = GrokLineBuffer()

    private let pid: pid_t
    private let stdinFD: Int32
    private let registryKey = UUID()
    private let drains = DispatchGroup()
    private let lock = NSLock()
    private var stdinClosed = false
    private var isTerminated = false

    // MARK: - Lifetime registry

    private final class Registry: @unchecked Sendable {
        /// Weak on purpose: the registry is a cleanup hook, not an owner. A
        /// process whose caller has gone away should be reclaimed (and killed by
        /// `deinit`), not kept alive by the very list meant to reap it.
        private final class WeakBox {
            weak var process: GrokAgentProcess?
            init(_ process: GrokAgentProcess) { self.process = process }
        }

        private let lock = NSLock()
        // Keyed by an owned token rather than by identity, so `terminate()` can
        // deregister from `deinit` without handing `self` back out mid-teardown.
        private var processes: [UUID: WeakBox] = [:]

        func insert(_ process: GrokAgentProcess, key: UUID) {
            lock.lock(); defer { lock.unlock() }
            processes[key] = WeakBox(process)
        }

        func remove(key: UUID) {
            lock.lock(); defer { lock.unlock() }
            processes.removeValue(forKey: key)
        }

        func terminateAll() {
            lock.lock()
            let live = processes.values.compactMap(\.process)
            processes.removeAll()
            lock.unlock()
            live.forEach { $0.terminate() }
        }
    }

    private static let registry = Registry()

    /// Kills any Grok agent still running. Called when the app terminates so a
    /// quit mid-refresh cannot leave an orphaned `grok` process behind.
    static func terminateAll() {
        registry.terminateAll()
    }

    // MARK: - Launch

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let inPipe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        let outPipe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        let errPipe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { inPipe.deallocate(); outPipe.deallocate(); errPipe.deallocate() }
        guard pipe(inPipe) == 0 else { throw Error.launchFailed }
        guard pipe(outPipe) == 0 else {
            close(inPipe[0]); close(inPipe[1])
            throw Error.launchFailed
        }
        guard pipe(errPipe) == 0 else {
            close(inPipe[0]); close(inPipe[1]); close(outPipe[0]); close(outPipe[1])
            throw Error.launchFailed
        }

        posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, inPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Spawned from a libdispatch worker whose signal mask may block SIGTERM;
        // clear it (and restore default dispositions) so the graceful stop can
        // actually reach the child instead of only the unblockable SIGKILL.
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

        var spawnedPID: pid_t = 0
        let spawnResult = posix_spawn(&spawnedPID, executable, &fileActions, &attributes, argv, envp)
        // The parent keeps only the ends it uses; closing the rest makes EOF real.
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard spawnResult == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw Error.launchFailed
        }

        pid = spawnedPID
        stdinFD = inPipe[1]
        // An agent that dies mid-conversation must fail our write with EPIPE
        // rather than raise SIGPIPE and take MeterBar down with it.
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        drain(fd: outPipe[0], endsStream: true) { [lines] data in lines.append(data) }
        // Grok's stderr can carry account metadata, so it is drained purely to
        // keep the pipe from filling — the bytes are counted by nobody and kept
        // by nothing. It also must not end the stream: an agent that closes
        // stderr early would otherwise cut short a reply still arriving on stdout.
        drain(fd: errPipe[0], endsStream: false) { _ in }

        Self.registry.insert(self, key: registryKey)
    }

    deinit {
        terminate()
    }

    // MARK: - I/O

    /// Writes one framed request line to the agent's stdin.
    func write(_ data: Data) throws {
        lock.lock()
        let closed = stdinClosed
        lock.unlock()
        guard !closed else { throw Error.writeFailed }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(stdinFD, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    throw Error.writeFailed
                }
            }
        }
    }

    /// Closes stdin, which is how a well-behaved ACP agent is told to shut down.
    func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        close(stdinFD)
    }

    // MARK: - Termination

    /// Stops the agent and everything it spawned. Idempotent, and safe to call
    /// from the request path, from `deinit`, and from app termination.
    func terminate() {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        isTerminated = true
        let alreadyClosed = stdinClosed
        stdinClosed = true
        lock.unlock()

        if !alreadyClosed {
            close(stdinFD)
        }
        Self.registry.remove(key: registryKey)

        // Graceful first: closing stdin already asked the agent to stop, so give
        // SIGTERM a bounded grace before killing the group outright.
        _ = kill(-pid, SIGTERM)
        var status: Int32 = 0
        var reaped = false
        let graceDeadline = Date().addingTimeInterval(Self.terminationGrace)
        while Date() < graceDeadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                break
            }
            usleep(20_000)
        }
        // Kill the group even after a clean exit: a grandchild that ignored
        // SIGTERM would otherwise outlive the request. While any member of the
        // group survives, the pid cannot be recycled as another group's leader,
        // so this can never reach an unrelated tree.
        _ = kill(-pid, SIGKILL)
        if !reaped {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {
                continue
            }
        }

        // Bounded: a descendant that re-sessioned via setsid() can hold a write
        // end open past the group kill, and one leaked drain thread is better
        // than blocking the refresh forever.
        _ = drains.wait(timeout: .now() + Self.drainGrace)
        lines.finish()
    }

    private func drain(fd: Int32, endsStream: Bool, into sink: @escaping @Sendable (Data) -> Void) {
        let queue = DispatchQueue(label: "dev.meterbar.app.grok.drain.\(fd)")
        drains.enter()
        queue.async { [drains, lines] in
            defer {
                close(fd)
                // Flush the trailing partial line before releasing the group, so
                // anyone waiting on the drains sees the complete stream.
                if endsStream {
                    lines.finish()
                }
                drains.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    sink(Data(buffer[0..<count]))
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}
