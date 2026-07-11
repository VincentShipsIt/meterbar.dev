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
