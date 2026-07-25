import XCTest
@testable import MeterBar

/// Coverage for #97's low-level launcher: concurrent bounded draining, timeout
/// with process-tree cleanup, and cancellation.
final class ManagedProcessTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Resolve /var → /private/var so a child's physical `pwd` matches.
        tempDir = tempDir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A fake executable driven entirely by environment variables so tests can
    /// shape its argv record, sleep, child-spawn, output volume, and exit code.
    private func makeFake() throws -> String {
        let script = """
        #!/bin/bash
        if [ -n "$WAKE_TEST_OUT" ]; then
          { echo "ARGS:$*"; echo "PWD:$(pwd)"; echo "CFG:${CLAUDE_CONFIG_DIR}"; echo "TERM:${TERM}"; } >> "$WAKE_TEST_OUT"
        fi
        if [ -n "$WAKE_STDOUT_MSG" ]; then echo "$WAKE_STDOUT_MSG"; fi
        if [ -n "$WAKE_STDERR_MSG" ]; then echo "$WAKE_STDERR_MSG" >&2; fi
        if [ -n "$WAKE_SPAWN_CHILD" ]; then
          sleep 30 &
          echo $! > "$WAKE_CHILD_PID"
        fi
        if [ -n "$WAKE_STDOUT_BYTES" ]; then
          head -c "$WAKE_STDOUT_BYTES" /dev/zero | tr '\\0' 'x'
        fi
        if [ -n "$WAKE_SLEEP" ]; then sleep "$WAKE_SLEEP"; fi
        exit "${WAKE_EXIT:-0}"
        """
        let url = tempDir.appendingPathComponent("fake.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func run(
        _ fake: String,
        env: [String: String],
        timeout: TimeInterval,
        cancellation: ManagedProcess.Cancellation = .init()
    ) async -> ManagedProcess.Result {
        var env = env
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin" // child needs sleep/head/tr
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = ManagedProcess.run(
                    executable: fake,
                    arguments: ["-r", "sid", "-p", "continue"],
                    environment: env,
                    workingDirectory: self.tempDir.path,
                    timeout: timeout,
                    cancellation: cancellation
                )
                continuation.resume(returning: result)
            }
        }
    }

    func testExitCodeAndCwdArePropagated() async throws {
        let fake = try makeFake()
        let out = tempDir.appendingPathComponent("out.txt").path
        let result = await run(fake, env: ["WAKE_TEST_OUT": out, "WAKE_EXIT": "0"], timeout: 10)
        XCTAssertEqual(result.termination, .exited(code: 0))
        let recorded = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(recorded.contains("ARGS:-r sid -p continue"), "recorded=\(recorded)")
        // Prefix-independent (avoids /var vs /private/var): the child chdir'd
        // into our unique temp dir.
        XCTAssertTrue(recorded.contains("PWD:") && recorded.contains(tempDir.lastPathComponent),
                      "recorded=\(recorded)")
    }

    func testNonZeroExitIsReported() async throws {
        let fake = try makeFake()
        let result = await run(fake, env: ["WAKE_EXIT": "7"], timeout: 10)
        XCTAssertEqual(result.termination, .exited(code: 7))
        XCTAssertFalse(result.isSuccess)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let fake = try makeFake()
        // 500 KB ≫ the 16 KB read buffer and the 64 KB cap.
        let result = await run(fake, env: ["WAKE_STDOUT_BYTES": "500000"], timeout: 10)
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertGreaterThan(result.stdoutByteCount, 400_000)
    }

    func testTimeoutKillsProcessTree() async throws {
        let fake = try makeFake()
        let childPidFile = tempDir.appendingPathComponent("child.pid")
        let result = await run(
            fake,
            env: ["WAKE_SLEEP": "30", "WAKE_SPAWN_CHILD": "1", "WAKE_CHILD_PID": childPidFile.path],
            timeout: 1
        )
        XCTAssertEqual(result.termination, .timedOut)

        // The spawned child must have been killed with the group.
        let childPid = try pid(from: childPidFile)
        try await waitForProcessGone(childPid)
        XCTAssertFalse(processAlive(childPid), "Child process leaked after timeout")
    }

    func testParentEnvironmentDoesNotLeakToChild() async throws {
        // A variable present only in the parent must NOT reach the child: the
        // launcher builds envp solely from the provided environment, verbatim.
        setenv("WAKE_SHOULD_NOT_LEAK", "leaked", 1)
        defer { unsetenv("WAKE_SHOULD_NOT_LEAK") }

        let marker = tempDir.appendingPathComponent("env.txt")
        let script = """
        #!/bin/bash
        printf '%s' "${WAKE_SHOULD_NOT_LEAK:-ABSENT}" > "$WAKE_ENV_OUT"
        """
        let url = tempDir.appendingPathComponent("env.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let result = await run(url.path, env: ["WAKE_ENV_OUT": marker.path], timeout: 10)
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ABSENT")
    }

    func testLargeOutputTruncatesCaptureWithoutDeadlock() async throws {
        let fake = try makeFake()
        // 4 MiB ≫ the 16 KiB read buffer and the 64 KiB capture cap.
        let result = await run(fake, env: ["WAKE_STDOUT_BYTES": "4194304"], timeout: 20)
        XCTAssertEqual(result.termination, .exited(code: 0))
        // Every byte is drained (proving no pipe-buffer deadlock)…
        XCTAssertGreaterThan(result.stdoutByteCount, 4_000_000)
        // …while the stream is reported as truncated past the capture cap.
        XCTAssertTrue(result.stdoutTruncated, "stream beyond the cap must report truncation")
        XCTAssertFalse(result.stderrTruncated)
        // The retained capture never grows past the cap, no matter the stream size.
        XCTAssertLessThanOrEqual(result.stdoutCapture.count, 64 * 1024,
                                 "bounded capture must never exceed maxCaptureBytes")
        XCTAssertEqual(result.stderrCapture.count, 0)
    }

    func testBoundedCaptureRetainsStreamContent() async throws {
        let fake = try makeFake()
        let result = await run(
            fake,
            env: [
                "WAKE_STDOUT_MSG": "resuming session sid",
                "WAKE_STDERR_MSG": "this tool requires approval before running",
                "WAKE_EXIT": "1"
            ],
            timeout: 10
        )
        XCTAssertEqual(result.termination, .exited(code: 1))
        let stdout = String(data: result.stdoutCapture, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderrCapture, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("resuming session sid"), "stdout capture missing: \(stdout)")
        XCTAssertTrue(stderr.contains("requires approval"), "stderr capture missing: \(stderr)")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
    }

    func testCaptureRetainsLeadingBytesWhenTruncated() async throws {
        let fake = try makeFake()
        // A marker printed *before* the flood must survive: the sink keeps the
        // leading bytes and discards everything past the cap.
        let result = await run(
            fake,
            env: ["WAKE_STDOUT_MSG": "MARKER-HEAD", "WAKE_STDOUT_BYTES": "500000"],
            timeout: 20
        )
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertLessThanOrEqual(result.stdoutCapture.count, 64 * 1024)
        let head = String(data: result.stdoutCapture.prefix(64), encoding: .utf8) ?? ""
        XCTAssertTrue(head.contains("MARKER-HEAD"), "leading bytes must be retained, got: \(head)")
    }

    func testDrainDoesNotHangWhenGrandchildHoldsStdoutOpen() async throws {
        let fake = try makeFake()
        let childPidFile = tempDir.appendingPathComponent("child.pid")
        // The child spawns `sleep 30 &` (which inherits the stdout pipe) and exits
        // 0 immediately without waiting. The reaped child is gone, but the
        // grandchild keeps the pipe's write end open, so the drain never sees EOF.
        // run() must fall back to a bounded drain wait, then SIGKILL the group.
        let started = Date()
        let result = await run(
            fake,
            env: ["WAKE_SPAWN_CHILD": "1", "WAKE_CHILD_PID": childPidFile.path],
            timeout: 30
        )
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "run() hung on the inherited-fd drain")

        // The bounded-drain fallback SIGKILLs the whole group, reaping the leaked
        // grandchild that was holding the pipe open.
        let childPid = try pid(from: childPidFile)
        try await waitForProcessGone(childPid)
        XCTAssertFalse(processAlive(childPid), "grandchild holding stdout open was not cleaned up")
    }

    func testTimeoutSendsSIGTERMBeforeSIGKILL() async throws {
        let marker = tempDir.appendingPathComponent("term.marker")
        // Trap SIGTERM, record it, and exit. A straight SIGKILL cannot be trapped,
        // so a written marker proves graceful escalation delivered SIGTERM first.
        let script = """
        #!/bin/bash
        trap 'echo TERMED > "$WAKE_TERM_MARKER"; exit 42' TERM
        sleep 120 &
        wait
        """
        let url = tempDir.appendingPathComponent("trap.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        // Generous timeout so a slow CI runner has installed the trap before
        // SIGTERM lands; the default disposition would kill bash markerless.
        let result = await run(url.path, env: ["WAKE_TERM_MARKER": marker.path], timeout: 2.5)
        XCTAssertEqual(result.termination, .timedOut)
        let recorded = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(recorded.contains("TERMED"), "child did not receive SIGTERM before SIGKILL")
    }

    func testCancellationKillsGroupAndReportsCancelled() async throws {
        let fake = try makeFake()
        let childPidFile = tempDir.appendingPathComponent("child.pid")
        let cancellation = ManagedProcess.Cancellation()
        async let resultTask = run(
            fake,
            env: ["WAKE_SLEEP": "30", "WAKE_SPAWN_CHILD": "1", "WAKE_CHILD_PID": childPidFile.path],
            timeout: 30,
            cancellation: cancellation
        )
        // Give it a moment to spawn, then cancel.
        try await Task.sleep(nanoseconds: 400_000_000)
        cancellation.cancel()
        let result = await resultTask
        XCTAssertEqual(result.termination, .cancelled)

        let childPid = try pid(from: childPidFile)
        try await waitForProcessGone(childPid)
        XCTAssertFalse(processAlive(childPid), "Child process leaked after cancellation")
    }

    // MARK: - Descriptor hygiene

    /// `pipe()` for stderr can fail after the stdout pair already exists. Those
    /// two descriptors have no owner at that point — nothing is spawned, no
    /// drain is running — so bailing out without closing them strands a pair per
    /// call until the process exits.
    func testFailedSecondPipeDoesNotLeakTheFirstPair() throws {
        var hogged: [Int32] = []
        // Take the whole descriptor table, then hand back exactly three slots:
        // enough for the stdout pipe and one spare, never enough for stderr's.
        while hogged.count < 200_000 {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            if descriptor < 0 { break }
            hogged.append(descriptor)
        }
        guard (8..<200_000).contains(hogged.count) else {
            for descriptor in hogged { close(descriptor) }
            throw XCTSkip("descriptor limit (\(hogged.count) free) cannot be exhausted safely here")
        }
        for _ in 0 ..< 3 { close(hogged.removeLast()) }

        let result = ManagedProcess.run(
            executable: "/bin/echo",
            arguments: [],
            environment: [:],
            workingDirectory: tempDir.path,
            timeout: 5
        )

        // Probe *before* releasing the hogged descriptors: only the launcher
        // giving the stdout pair back leaves room for another pipe.
        let probe = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        let probeSucceeded = pipe(probe) == 0
        if probeSucceeded { close(probe[0]); close(probe[1]) }
        probe.deallocate()

        // Restore the table before asserting — a failing assertion needs
        // descriptors of its own to report itself.
        for descriptor in hogged { close(descriptor) }

        XCTAssertEqual(result.termination, .launchFailed("pipe() failed"))
        XCTAssertTrue(probeSucceeded, "the stdout pipe was leaked when the stderr pipe failed")
    }

    // MARK: - Wait-poll interruption

    /// A signal delivered to the waiting thread aborts `waitpid` with `EINTR`
    /// and tells us nothing about the child. Treating that as a failure would
    /// abandon a live process group un-reaped.
    func testInterruptedPollIsRetriedRatherThanReportedAsFailure() {
        var polls = 0
        let termination = ManagedProcess.wait(
            pid: 4242,
            timeout: 10,
            cancellation: .init(),
            poll: { pid -> (result: pid_t, status: Int32, errorNumber: Int32) in
                polls += 1
                if polls <= 3 { return (-1, 0, EINTR) }
                return (pid, 0, 0)
            },
            escalate: { _ in XCTFail("a retried poll must not escalate to a kill") }
        )

        XCTAssertEqual(termination, .exited(code: 0))
        XCTAssertEqual(polls, 4, "each interruption must cost exactly one retry")
    }

    /// EINTR is the only recoverable `-1`. `ECHILD` means the child is not ours
    /// to wait for and retrying would spin until the deadline.
    func testUnrecoverablePollErrorIsStillReportedAsFailure() {
        let termination = ManagedProcess.wait(
            pid: 4242,
            timeout: 10,
            cancellation: .init(),
            poll: { _ in (-1, 0, ECHILD) },
            escalate: { _ in XCTFail("a fatal poll error must not escalate to a kill") }
        )

        guard case let .launchFailed(message) = termination else {
            return XCTFail("expected launchFailed, got \(termination)")
        }
        XCTAssertTrue(message.contains("waitpid"), "message should name the failing call: \(message)")
        XCTAssertTrue(message.contains("\(ECHILD)"), "message should carry the errno: \(message)")
    }

    /// Retrying must not become an unbounded loop: an interruption that never
    /// stops still has to hit the timeout and kill the tree.
    func testUnendingInterruptionsStillHonourTheTimeout() {
        var escalated: [pid_t] = []
        let termination = ManagedProcess.wait(
            pid: 4242,
            timeout: 0,
            cancellation: .init(),
            poll: { _ in (-1, 0, EINTR) },
            escalate: { escalated.append($0) }
        )

        XCTAssertEqual(termination, .timedOut)
        XCTAssertEqual(escalated, [4242], "the timeout path must still escalate exactly once")
    }

    /// The poll seam must not change how a reaped child is classified.
    func testSignalledChildIsClassifiedThroughThePollSeam() {
        let termination = ManagedProcess.wait(
            pid: 4242,
            timeout: 10,
            cancellation: .init(),
            poll: { pid in (pid, SIGKILL, 0) },
            escalate: { _ in XCTFail("a reaped child must not escalate to a kill") }
        )

        XCTAssertEqual(termination, .signalled(signal: SIGKILL))
    }

    /// A cancel that lands before the poll observes the exit still reports
    /// `.cancelled` rather than the SIGKILL that carried it out.
    func testCancellationOutranksTheReapedStatus() {
        let cancellation = ManagedProcess.Cancellation()
        cancellation.cancel()

        let termination = ManagedProcess.wait(
            pid: 4242,
            timeout: 10,
            cancellation: cancellation,
            poll: { pid in (pid, SIGKILL, 0) },
            escalate: { _ in XCTFail("a reaped child must not escalate to a kill") }
        )

        XCTAssertEqual(termination, .cancelled)
    }

    // MARK: - Process helpers

    private func pid(from file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text) ?? -1
    }

    private func processAlive(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    private func waitForProcessGone(_ pid: pid_t, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while processAlive(pid) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
