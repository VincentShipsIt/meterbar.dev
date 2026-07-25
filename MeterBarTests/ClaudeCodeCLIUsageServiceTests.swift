import XCTest
@testable import MeterBar

final class ClaudeCodeCLIUsageServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeCLIUsageServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // Resolve /var → /private/var so a child's physical `pwd` matches.
        tempDirectory = tempDirectory.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Spawned environment

    /// The spawned `claude` must get an augmented PATH: under launchd's bare
    /// GUI PATH the CLI itself launches but cannot find `node`, prints a cost
    /// summary instead of the usage screen, and parsing fails with
    /// "No Claude usage windows found".
    func testProcessEnvironmentAugmentsPATH() {
        let environment = ClaudeCodeCLIUsageService.shared.processEnvironment(
            account: .defaultAccount,
            base: ["PATH": "/usr/bin:/bin"]
        )

        let path = environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"), "Inherited PATH entries must keep priority")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "Homebrew bin dir must be reachable for node")
    }

    func testProcessEnvironmentSetsPlainTerminalAndConfigDirectory() {
        let account = ClaudeCodeAccount(id: UUID(), name: "alt", configDirectory: "/tmp/claude-alt")
        let environment = ClaudeCodeCLIUsageService.shared.processEnvironment(
            account: account,
            base: [:]
        )

        XCTAssertEqual(environment["NO_COLOR"], "1")
        XCTAssertEqual(environment["TERM"], "dumb")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-alt")
    }

    // MARK: - Launch path

    /// The regression this launch path exists for: a CLI whose output exceeds
    /// the 64 KB pipe buffer. Draining only after the child exits deadlocks —
    /// the child blocks on write, never exits, and every run times out.
    /// Concurrent draining must return the leading usage screen well inside the
    /// timeout.
    func testLargeUsageOutputIsReturnedWithoutPipeDeadlock() async throws {
        let binary = try makeFakeCLI(named: "flood.sh", body: """
        echo "Current session: 42% used (resets Jul 24 at 6pm)"
        head -c 524288 /dev/zero | tr '\\0' 'x'
        """)

        let started = Date()
        let output = try (await runBlocking(binaryPath: binary, timeout: 10)).get()

        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "large output must not stall the run")
        XCTAssertTrue(output.contains("Current session: 42% used"), "leading usage screen must survive")
        XCTAssertNoThrow(try ClaudeCodeCLIUsageParser.parseMetrics(from: output))
    }

    func testNonZeroExitSurfacesStderr() async throws {
        let binary = try makeFakeCLI(named: "fail.sh", body: """
        echo "not logged in" >&2
        exit 3
        """)

        let result = await runBlocking(binaryPath: binary)

        guard case let .failure(error) = result,
              case let ClaudeCodeCLIUsageError.commandFailed(message) = error else {
            return XCTFail("expected commandFailed, got \(result)")
        }
        XCTAssertTrue(message.contains("not logged in"), "message=\(message)")
    }

    func testNonZeroExitWithSilentStderrFallsBackToStdout() async throws {
        let binary = try makeFakeCLI(named: "quiet-fail.sh", body: """
        echo "usage unavailable"
        exit 1
        """)

        let result = await runBlocking(binaryPath: binary)

        guard case let .failure(error) = result,
              case let ClaudeCodeCLIUsageError.commandFailed(message) = error else {
            return XCTFail("expected commandFailed, got \(result)")
        }
        XCTAssertTrue(message.contains("usage unavailable"), "message=\(message)")
    }

    func testTimeoutIsReportedWithoutWaitingOutTheChild() async throws {
        let binary = try makeFakeCLI(named: "hang.sh", body: "sleep 30")

        let started = Date()
        let result = await runBlocking(binaryPath: binary, timeout: 1)

        guard case let .failure(error) = result,
              case ClaudeCodeCLIUsageError.timedOut = error else {
            return XCTFail("expected timedOut, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "timeout must not wait out the child")
    }

    /// A timed-out CLI must not leave a backgrounded grandchild running: the
    /// launcher spawns into its own process group and kills the whole tree.
    func testTimeoutKillsTheProcessTree() async throws {
        let childPidFile = tempDirectory.appendingPathComponent("child.pid")
        let binary = try makeFakeCLI(named: "hang-with-child.sh", body: """
        sleep 30 &
        echo $! > "\(childPidFile.path)"
        sleep 30
        """)

        let result = await runBlocking(binaryPath: binary, timeout: 1)

        guard case let .failure(error) = result,
              case ClaudeCodeCLIUsageError.timedOut = error else {
            return XCTFail("expected timedOut, got \(result)")
        }
        let childPid = try pid(from: childPidFile)
        try await waitForProcessGone(childPid)
        XCTAssertFalse(processAlive(childPid), "grandchild leaked after timeout")
    }

    func testMissingBinaryIsReportedAsLaunchFailure() async throws {
        let missing = tempDirectory.appendingPathComponent("does-not-exist").path

        let result = await runBlocking(binaryPath: missing)

        guard case let .failure(error) = result,
              case ClaudeCodeCLIUsageError.launchFailed = error else {
            return XCTFail("expected launchFailed, got \(result)")
        }
    }

    /// The CLI resolves its credentials relative to the user's real home, so the
    /// child must be chdir'd there rather than inheriting the app's cwd.
    func testChildRunsFromRealHomeWithTheConfiguredAccountDirectory() async throws {
        let marker = tempDirectory.appendingPathComponent("child-env.txt")
        let binary = try makeFakeCLI(named: "record.sh", body: """
        { echo "PWD:$(pwd)"; echo "TERM:${TERM}"; echo "CFG:${CLAUDE_CONFIG_DIR}"; } > "\(marker.path)"
        echo "Current session: 10% used"
        """)
        let account = ClaudeCodeAccount(id: UUID(), name: "alt", configDirectory: "/tmp/claude-alt")

        _ = try (await runBlocking(binaryPath: binary, account: account)).get()

        let home = URL(fileURLWithPath: ServiceSupport.realHomeDirectory())
            .resolvingSymlinksInPath().path
        let recorded = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(recorded.contains("PWD:\(home)"), "recorded=\(recorded)")
        XCTAssertTrue(recorded.contains("TERM:dumb"), "recorded=\(recorded)")
        XCTAssertTrue(recorded.contains("CFG:/tmp/claude-alt"), "recorded=\(recorded)")
    }

    // MARK: - Helpers

    private func makeFakeCLI(named name: String, body: String) throws -> String {
        let url = tempDirectory.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// `runClaudeUsageBlocking` blocks its thread by design; mirror production
    /// by hopping off the cooperative pool before calling it.
    private func runBlocking(
        binaryPath: String,
        account: ClaudeCodeAccount = .defaultAccount,
        timeout: TimeInterval = 10
    ) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Result {
                    try ClaudeCodeCLIUsageService.shared.runClaudeUsageBlocking(
                        binaryPath: binaryPath,
                        account: account,
                        timeout: timeout
                    )
                })
            }
        }
    }

    /// Fails loudly on an unreadable pid file instead of returning a sentinel:
    /// a `-1` here makes `processAlive` false forever, so the leak assertions
    /// would pass without ever having observed the grandchild they guard.
    private func pid(from file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try XCTUnwrap(pid_t(text), "unparsable pid file contents: \(text)")
        XCTAssertGreaterThan(parsed, 0, "pid file must name a real process")
        return parsed
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
