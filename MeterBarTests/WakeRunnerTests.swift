import XCTest
@testable import MeterBar

/// Coverage for #97: the runner's argv/env/cwd contract, structured skip/fail
/// outcomes, the shared lock, safe-by-default permissions, and private logging.
final class WakeRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDir = tempDir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFake() throws -> String {
        let script = """
        #!/bin/bash
        if [ -n "$WAKE_TEST_OUT" ]; then
          { echo "ARGS:$*"; echo "PWD:$(pwd)"; echo "CFG:${CLAUDE_CONFIG_DIR}"; } >> "$WAKE_TEST_OUT"
        fi
        exit "${WAKE_EXIT:-0}"
        """
        let url = tempDir.appendingPathComponent("fake.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func candidate(sessionID: String = "sid-1", cwd: String?) -> WakeSessionCandidate {
        let at = Date(timeIntervalSince1970: 1_000)
        return WakeSessionCandidate(
            sessionID: sessionID,
            transcriptPath: tempDir.appendingPathComponent("\(sessionID).jsonl").path,
            workingDirectory: cwd,
            gitBranch: "main",
            reason: .sessionLimit,
            blockedAt: at,
            resetHint: nil,
            fingerprint: BlockFingerprint(sessionID: sessionID, blockedAt: at, reason: .sessionLimit),
            skipReason: nil
        )
    }

    private func account() -> ClaudeCodeAccount {
        ClaudeCodeAccount(id: UUID(), name: "acct", configDirectory: tempDir.appendingPathComponent("cfg").path)
    }

    private func makeRunner(
        fake: String,
        env: [String: String],
        permissionMode: WakePermissionMode = .safe,
        bypassAcknowledged: Bool = false,
        logDir: URL? = nil
    ) -> WakeProcessRunner {
        var env = env
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin"
        let lockURL = tempDir.appendingPathComponent("wake.lock")
        return WakeProcessRunner(
            account: account(),
            executable: fake,
            permissionMode: permissionMode,
            bypassAcknowledged: bypassAcknowledged,
            baseEnvironment: env,
            lockFactory: { WakeLock(lockURL: lockURL, legacyLockURLs: []) },
            logger: WakeRunLogger(directory: logDir ?? self.tempDir.appendingPathComponent("logs"))
        )
    }

    // MARK: - Command builder

    func testSafePermissionByDefault() {
        let command = WakeCommandBuilder.build(
            executable: "/bin/claude",
            candidate: candidate(cwd: tempDir.path),
            account: account(),
            bounds: .default
        )
        XCTAssertTrue(command.arguments.contains("--permission-mode"))
        XCTAssertTrue(command.arguments.contains("default"))
        XCTAssertFalse(command.arguments.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(command.environment["CLAUDE_CONFIG_DIR"], account().configDirectory)
    }

    func testBypassRequiresAcknowledgement() {
        let unacknowledged = WakeCommandBuilder.build(
            executable: "/bin/claude", candidate: candidate(cwd: tempDir.path), account: account(),
            bounds: .default, permissionMode: .bypass, bypassAcknowledged: false
        )
        XCTAssertFalse(unacknowledged.arguments.contains("--dangerously-skip-permissions"),
                       "Bypass must not be silently emitted without acknowledgement")

        let acknowledged = WakeCommandBuilder.build(
            executable: "/bin/claude", candidate: candidate(cwd: tempDir.path), account: account(),
            bounds: .default, permissionMode: .bypass, bypassAcknowledged: true
        )
        XCTAssertTrue(acknowledged.arguments.contains("--dangerously-skip-permissions"))
    }

    func testMaxTurnsAndSessionArgs() {
        let command = WakeCommandBuilder.build(
            executable: "/bin/claude", candidate: candidate(sessionID: "abc", cwd: tempDir.path),
            account: account(), bounds: .default
        )
        XCTAssertTrue(command.arguments.contains("abc"))
        XCTAssertTrue(command.arguments.contains("--max-turns"))
        XCTAssertTrue(command.arguments.contains(String(WakeBounds.default.maxTurns)))
    }

    // MARK: - Runner

    func testRunPassesExactArgvEnvAndCwd() async throws {
        let fake = try makeFake()
        let out = tempDir.appendingPathComponent("out.txt")
        let runner = makeRunner(fake: fake, env: ["WAKE_TEST_OUT": out.path])
        let outcome = await runner.run(candidate(sessionID: "sid-x", cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(outcome, .succeeded)
        let recorded = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(recorded.contains("-r sid-x"))
        XCTAssertTrue(recorded.contains("--permission-mode default"))
        XCTAssertTrue(recorded.contains("PWD:") && recorded.contains(tempDir.lastPathComponent))
        XCTAssertTrue(recorded.contains("CFG:\(account().configDirectory!)"))
    }

    func testDeadWorktreeIsSkippedWithoutLaunching() async throws {
        let fake = try makeFake()
        let out = tempDir.appendingPathComponent("out.txt")
        let runner = makeRunner(fake: fake, env: ["WAKE_TEST_OUT": out.path])
        let deadCwd = tempDir.appendingPathComponent("gone").path
        let outcome = await runner.run(candidate(cwd: deadCwd), bounds: .default)
        XCTAssertEqual(outcome, .skipped(reason: .missingWorkingDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "Skipped session must not launch")
    }

    func testNonZeroExitIsStructuredFailureNotBypassEscalation() async throws {
        let fake = try makeFake()
        let out = tempDir.appendingPathComponent("out.txt")
        let runner = makeRunner(fake: fake, env: ["WAKE_TEST_OUT": out.path, "WAKE_EXIT": "5"])
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        if case .failed = outcome {} else { XCTFail("Expected structured failure, got \(outcome)") }
        // Exactly one invocation, and it never escalated to bypass.
        let recorded = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(recorded.components(separatedBy: "ARGS:").count - 1, 1)
        XCTAssertFalse(recorded.contains("--dangerously-skip-permissions"))
    }

    // MARK: - Lock

    func testSharedLockRejectsContention() {
        let url = tempDir.appendingPathComponent("shared.lock")
        let first = WakeLock(lockURL: url, legacyLockURLs: [])
        let second = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(first.acquire(), .acquired)
        XCTAssertEqual(second.acquire(), .contended)
        first.release()
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
    }

    func testLegacyWatcherContentionIsReported() {
        let legacy = tempDir.appendingPathComponent("legacy.lock")
        FileManager.default.createFile(atPath: legacy.path, contents: nil)
        // Hold the legacy lock from a separate descriptor.
        let heldFd = open(legacy.path, O_RDWR)
        defer { close(heldFd) }
        XCTAssertEqual(flock(heldFd, LOCK_EX | LOCK_NB), 0)

        let lock = WakeLock(lockURL: tempDir.appendingPathComponent("ours.lock"), legacyLockURLs: [legacy])
        if case .legacyHeld = lock.acquire() {} else {
            XCTFail("Expected legacyHeld guidance when a legacy watcher holds its lock")
        }
    }

    // MARK: - Logging

    func testLogsAreStructuredMetadataOnlyWithPrivatePermissions() async throws {
        let fake = try makeFake()
        let logDir = tempDir.appendingPathComponent("logs")
        let runner = makeRunner(fake: fake, env: [:], logDir: logDir)
        _ = await runner.run(candidate(sessionID: "sid-log", cwd: tempDir.path), bounds: .default)

        // Directory 0700.
        let dirPerms = try FileManager.default.attributesOfItem(atPath: logDir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)

        let logFile = try XCTUnwrap(FileManager.default
            .contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "log" }))
        let filePerms = try FileManager.default.attributesOfItem(atPath: logFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600)

        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"sessionID\":\"sid-log\""))
        XCTAssertTrue(contents.contains("\"outcome\":\"succeeded\""))
        // No prompt, no raw output tails.
        XCTAssertFalse(contents.contains("continue"))
        XCTAssertFalse(contents.lowercased().contains("stdout\":\""))
    }
}
