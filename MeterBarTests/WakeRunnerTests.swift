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
        if [ -n "$WAKE_STDERR_MSG" ]; then echo "$WAKE_STDERR_MSG" >&2; fi
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

    /// GUI launches inherit launchd's bare PATH; without augmentation the
    /// resumed `claude` cannot find `node` and the wake silently fails.
    func testBuildAugmentsPATHWithCLIInstallDirectories() {
        let command = WakeCommandBuilder.build(
            executable: "/bin/claude", candidate: candidate(cwd: tempDir.path), account: account(),
            bounds: .default, baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        let path = command.environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"), "Inherited PATH entries must keep priority")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "Homebrew bin dir must be reachable for node")
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

    // MARK: - Permission-denial classification

    func testPermissionDenialOnNonZeroExitIsStructuredOutcome() async throws {
        let fake = try makeFake()
        let runner = makeRunner(
            fake: fake,
            env: ["WAKE_STDERR_MSG": "Bash requires approval before it can run", "WAKE_EXIT": "1"]
        )
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(outcome, .permissionDenied,
                       "A non-zero exit whose output signals the approval gate must classify as permissionDenied")
    }

    func testPermissionDenialSurvivesCaptureTruncatedMidMultibyte() async throws {
        // The bounded capture keeps the leading 64 KiB; when that boundary
        // splits a multibyte character, a STRICT utf8 decode returns nil and
        // would drop the whole capture — losing the denial phrase in exactly
        // the long-output case the sink exists for. Lossy decoding must retain
        // it. The fake emits the phrase, then enough 3-byte characters that the
        // 65536-byte boundary lands one byte into the final character.
        let denialFake = tempDir.appendingPathComponent("denial-fill.sh")
        // Raw string so `\n` and `\x{597d}` reach bash/perl literally, not the
        // Swift compiler. 18-byte phrase + 21840×3-byte chars = 65538 bytes;
        // the retained leading 65536 ends one byte into the final character.
        let script = #"""
        #!/bin/bash
        { printf 'requires approval\n'; perl -e 'print "\x{597d}" x 21840'; } >&2
        exit 1
        """#
        try script.write(to: denialFake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denialFake.path)

        let runner = makeRunner(fake: denialFake.path, env: [:])
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(outcome, .permissionDenied,
                       "A denial phrase must classify even when the capture is truncated mid-character")
    }

    func testDenialPhrasesOnSuccessfulExitStaySuccess() async throws {
        let fake = try makeFake()
        // A run that *mentions* permissions but exits 0 succeeded — classification
        // only applies to non-zero exits.
        let runner = makeRunner(
            fake: fake,
            env: ["WAKE_STDERR_MSG": "permission denied earlier, but recovered", "WAKE_EXIT": "0"]
        )
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(outcome, .succeeded)
    }

    func testNonDenialFailureStaysGenericFailure() async throws {
        let fake = try makeFake()
        let runner = makeRunner(
            fake: fake,
            env: ["WAKE_STDERR_MSG": "fatal: repository not found", "WAKE_EXIT": "5"]
        )
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        if case .failed = outcome {} else {
            XCTFail("Unrelated failure must not classify as permissionDenied, got \(outcome)")
        }
    }

    func testPermissionDenialContentNeverReachesLogs() async throws {
        let fake = try makeFake()
        let logDir = tempDir.appendingPathComponent("denial-logs")
        let runner = makeRunner(
            fake: fake,
            env: ["WAKE_STDERR_MSG": "SecretToolName requires approval", "WAKE_EXIT": "1"],
            logDir: logDir
        )
        let outcome = await runner.run(candidate(sessionID: "sid-denied", cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(outcome, .permissionDenied)

        let logFile = try XCTUnwrap(FileManager.default
            .contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "log" }))
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        // The structured label is logged; the captured output never is.
        XCTAssertTrue(contents.contains("\"outcome\":\"permission-denied\""), "log missing label: \(contents)")
        XCTAssertFalse(contents.contains("SecretToolName"), "raw output leaked into the log")
        XCTAssertFalse(contents.contains("requires approval"), "raw output leaked into the log")
    }

    func testDetectorMatchesApprovalGatePhrases() {
        for phrase in [
            "Error: Permission Denied while running Bash",
            "This tool requires approval",
            "the command needs approval before continuing",
            "run with --dangerously-skip-permissions to skip",
            "status: PERMISSION_DENIED",
            "Claude requires permission to use Write"
        ] {
            XCTAssertTrue(PermissionDenialDetector.indicatesDenial(in: phrase), "should match: \(phrase)")
        }
    }

    func testDetectorIgnoresUnrelatedFailures() {
        for phrase in [
            "",
            "fatal: repository not found",
            "error: ENOENT no such file or directory",
            "session limit reached, resets 3:00am"
        ] {
            XCTAssertFalse(PermissionDenialDetector.indicatesDenial(in: phrase), "should not match: \(phrase)")
        }
    }

    // MARK: - Lock

    func testSharedLockRejectsContentionAndReportsHolder() {
        let url = tempDir.appendingPathComponent("shared.lock")
        let first = WakeLock(lockURL: url, legacyLockURLs: [])
        let second = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(first.acquire(), .acquired)
        guard case let .contended(holder) = second.acquire() else {
            return XCTFail("Expected contention while first holds the lock")
        }
        // The holder descriptor written by `first` is readable by the contender.
        XCTAssertEqual(holder?.kind, .app)
        XCTAssertEqual(holder?.pid, getpid())
        XCTAssertEqual(holder?.host.isEmpty, false)
        first.release()
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
    }

    func testRunnerReleasesLockSoSequentialRunsSucceed() async throws {
        // The runner is the sole owner of the shared lock: it acquires when
        // ready and releases after. A second runner on the same file (the next
        // queued session) must then acquire cleanly — proving the lock is not
        // leaked across runs.
        // makeRunner pins one shared lock file, so two runners here contend on
        // the same lock exactly as sequential queued sessions do in production.
        let fake = try makeFake()
        let first = await makeRunner(fake: fake, env: [:])
            .run(candidate(sessionID: "a", cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(first, .succeeded)
        let second = await makeRunner(fake: fake, env: [:])
            .run(candidate(sessionID: "b", cwd: tempDir.path), bounds: .default)
        XCTAssertEqual(second, .succeeded, "runner must release its lock so the next queued run acquires")
    }

    func testLockHolderCarriesCLIKind() {
        let url = tempDir.appendingPathComponent("cli.lock")
        let cli = WakeLock(lockURL: url, legacyLockURLs: [], holderKind: .cli)
        XCTAssertEqual(cli.acquire(), .acquired)
        defer { cli.release() }
        let contender = WakeLock(lockURL: url, legacyLockURLs: [])
        guard case let .contended(holder) = contender.acquire() else {
            return XCTFail("Expected contention")
        }
        XCTAssertEqual(holder?.kind, .cli)
    }

    func testReleaseClearsHolderDescriptor() throws {
        let url = tempDir.appendingPathComponent("clear.lock")
        let lock = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(lock.acquire(), .acquired)
        lock.release()
        // A released lock must not leave a stale descriptor that a later
        // contender would misattribute the (now free) lock to.
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.isEmpty, "released lock left a stale holder descriptor")
    }

    func testLockDirectoryCreationFailureIsUnavailableNotContended() {
        // The lock's parent path runs through a regular file, so the private
        // directory cannot be created. That is an environment failure, not
        // another holder.
        let blocker = tempDir.appendingPathComponent("blocker-file")
        FileManager.default.createFile(atPath: blocker.path, contents: nil)
        let lock = WakeLock(
            lockURL: blocker.appendingPathComponent("sub").appendingPathComponent("wake.lock"),
            legacyLockURLs: []
        )
        guard case .unavailable = lock.acquire() else {
            return XCTFail("Directory-creation failure must be .unavailable, not contention")
        }
    }

    func testUnopenableLockFileIsUnavailableNotContended() throws {
        // The lock path itself is a directory: open(O_RDWR) fails outright.
        let dir = tempDir.appendingPathComponent("lock-is-a-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = WakeLock(lockURL: dir, legacyLockURLs: [])
        guard case .unavailable = lock.acquire() else {
            return XCTFail("Open failure must be .unavailable, not contention")
        }
    }

    func testRunnerContentionFailureNamesTheHolder() async throws {
        let fake = try makeFake()
        // Pre-hold the exact lock the runner uses, as a CLI-kind holder.
        let lockURL = tempDir.appendingPathComponent("wake.lock")
        let holder = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .cli)
        XCTAssertEqual(holder.acquire(), .acquired)
        defer { holder.release() }

        let runner = makeRunner(fake: fake, env: [:])
        let outcome = await runner.run(candidate(cwd: tempDir.path), bounds: .default)
        guard case let .failed(reason) = outcome else {
            return XCTFail("Expected structured failure on contention, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("cli"), "reason should name the holder kind: \(reason)")
        XCTAssertTrue(reason.contains("\(getpid())"), "reason should name the holder pid: \(reason)")
    }

    func testReacquireWhileHeldIsIdempotent() {
        let url = tempDir.appendingPathComponent("reacquire.lock")
        let lock = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(lock.acquire(), .acquired)
        // A second acquire must not open a new descriptor over the held one.
        XCTAssertEqual(lock.acquire(), .acquired)
        lock.release()
        // One release fully releases: another holder can take the lock.
        let other = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(other.acquire(), .acquired)
        other.release()
    }

    func testLockFileIsCreatedWithPrivatePermissions() throws {
        let url = tempDir.appendingPathComponent("perm.lock")
        let lock = WakeLock(lockURL: url, legacyLockURLs: [])
        XCTAssertEqual(lock.acquire(), .acquired)
        defer { lock.release() }
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "Lock file must be owner-only (0600)")
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

    func testPruneOldLogsRemovesFilesBeyondRetention() throws {
        let logDir = tempDir.appendingPathComponent("prune-logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fileManager = FileManager.default

        // One log aged past the 14-day window, one comfortably inside it. Pruning
        // keys off file modification time, so set those explicitly.
        let expired = logDir.appendingPathComponent("session-wake-old.log")
        let fresh = logDir.appendingPathComponent("session-wake-new.log")
        fileManager.createFile(atPath: expired.path, contents: Data("x".utf8))
        fileManager.createFile(atPath: fresh.path, contents: Data("y".utf8))
        try fileManager.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-30 * 86_400)], ofItemAtPath: expired.path)
        try fileManager.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-1 * 86_400)], ofItemAtPath: fresh.path)

        // Appending triggers pruneOldLogs against the injected clock.
        let logger = WakeRunLogger(directory: logDir, retentionDays: 14, now: { fixedNow })
        logger.append(WakeRunLogger.Record(
            timestamp: fixedNow, event: "wake", sessionID: "sid", reason: "sessionLimit",
            outcome: "succeeded", exitCode: 0, durationMilliseconds: 10, stdoutBytes: 1, stderrBytes: 0
        ))

        XCTAssertFalse(fileManager.fileExists(atPath: expired.path), "Log older than retention must be pruned")
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path), "Log within retention must be kept")
    }
}
