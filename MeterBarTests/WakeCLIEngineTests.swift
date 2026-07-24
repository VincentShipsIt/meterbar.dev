import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Coverage for #99's CLI engine: dry-run is read-only, every terminal state is
/// distinguishable, Codex is rejected, and the JSON contract is versioned.
final class WakeCLIEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeCLIEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDir = tempDir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSharedFeatureFlagDefaultsOnButExplicitOffBlocksCLI() {
        let suite = "WakeFeatureGateTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("test defaults should be available")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(SessionWakeCLI.isFeatureEnabled(userDefaults: defaults))
        defaults.set(false, forKey: SessionWakeCLI.sharedFeatureEnabledKey)
        XCTAssertFalse(SessionWakeCLI.isFeatureEnabled(userDefaults: defaults))
    }

    private func writeBlockedSession(_ id: String = "s0") throws {
        let projects = tempDir.appendingPathComponent("projects").appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "type": "assistant", "timestamp": "2026-07-10T02:00:00.000Z",
            "isApiErrorMessage": true, "apiErrorStatus": 429, "cwd": tempDir.path, "sessionId": id,
            "message": ["role": "assistant", "content": [["type": "text", "text": "session limit resets 3:00am (UTC)"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try String(decoding: data, as: UTF8.self)
            .write(to: projects.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    private func account() -> ClaudeCodeAccount {
        ClaudeCodeAccount(id: UUID(), name: "acct", configDirectory: tempDir.path)
    }

    private func makeFakeClaude(exitCode: Int32) throws -> String {
        let script = """
        #!/bin/bash
        exit \(exitCode)
        """
        let url = tempDir.appendingPathComponent("fake-claude.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// The real production wiring: the engine holds a `.cli` lock instance and
    /// the runner it makes holds a *separate* lock instance on the SAME file.
    /// If the engine held its lock across `resume()`, the runner's acquire would
    /// self-contend (same-process flock) and every real resume would fail. The
    /// engine must probe-and-release so the runner is the sole lock owner.
    func testRealRunnerResumesWithoutSelfContendingOnSharedLock() async throws {
        try writeBlockedSession()
        let fake = try makeFakeClaude(exitCode: 0)
        let sharedLockURL = tempDir.appendingPathComponent("wake.lock")
        let engine = WakeCLIEngine(
            discovery: SessionDiscovery(),
            authority: WakeQuotaAuthority(provider: FixedProvider(.open), maxAge: 3600, now: { Date() }),
            makeRunner: { runnerAccount in
                WakeProcessRunner.claude(
                    account: runnerAccount,
                    executable: fake,
                    baseEnvironment: ["PATH": "/usr/bin:/bin"],
                    lockFactory: { WakeLock(lockURL: sharedLockURL, legacyLockURLs: [], holderKind: .app) },
                    logger: WakeRunLogger(directory: self.tempDir.appendingPathComponent("logs"))
                )
            },
            ledgerFactory: { ReplayLedger(fileURL: self.tempDir.appendingPathComponent("l.json")) },
            lock: WakeLock(lockURL: sharedLockURL, legacyLockURLs: [], holderKind: .cli),
            bounds: .default
        )

        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .success, "Real resume must not self-contend on the shared wake lock")
        XCTAssertEqual(response.summary.resumed, 1)
        XCTAssertEqual(response.summary.failed, 0)
    }

    private func makeEngine(
        provider: any WakeQuotaProviding<ClaudeCodeAccount>,
        runner: WakeExecuting,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> WakeCLIEngine {
        WakeCLIEngine(
            discovery: SessionDiscovery(),
            authority: WakeQuotaAuthority(provider: provider, maxAge: 3600, now: { Date() }),
            makeRunner: { _ in runner },
            ledgerFactory: { ReplayLedger(fileURL: self.tempDir.appendingPathComponent("l.json")) },
            lock: WakeLock(lockURL: self.tempDir.appendingPathComponent("wake.lock"), legacyLockURLs: []),
            bounds: .default,
            shouldCancel: shouldCancel
        )
    }

    func testCodexProviderRejected() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner()
        let engine = makeEngine(provider: ThrowingProvider(), runner: runner)
        let response = await engine.run(provider: "codex", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .validationFailure)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty)
    }

    func testDryRunIsReadOnly() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner()
        // A throwing quota provider: if dry-run consulted quota, we'd know.
        let engine = makeEngine(provider: ThrowingProvider(), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: true, limit: nil)
        XCTAssertEqual(response.outcome, .success)
        XCTAssertTrue(response.dryRun)
        XCTAssertEqual(response.eligibleCount, 1)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty, "Dry-run must launch nothing")
    }

    func testQuotaUnknownLaunchesNothing() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner()
        let engine = makeEngine(provider: ThrowingProvider(), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .quotaUnknown)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty)
    }

    func testBlockedWithoutWait() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner()
        let engine = makeEngine(provider: FixedProvider(.blocked), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .blockedWithoutWait)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty)
    }

    func testAvailableResumesAndRecordsLedger() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner(outcome: .succeeded)
        let engine = makeEngine(provider: FixedProvider(.open), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .success)
        XCTAssertEqual(response.summary.resumed, 1)
        let ran = await runner.ran
        XCTAssertEqual(ran, ["s0"])

        // Ledger recorded ⇒ a rescan sees it as already handled.
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("l.json"))
        let rescan = await SessionDiscovery().discover(configDirectory: tempDir.path, ledger: ledger)
        XCTAssertEqual(rescan.first?.skipReason, .alreadyHandled)
    }

    func testPartialFailureWhenRunnerFails() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner(outcome: .failed(reason: "boom"))
        let engine = makeEngine(provider: FixedProvider(.open), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .partialFailure)
        XCTAssertEqual(response.summary.failed, 1)
    }

    func testPermissionDenialCountsAsFailureNotSuccess() async throws {
        try writeBlockedSession()
        let runner = RecordingRunner(outcome: .permissionDenied)
        let engine = makeEngine(provider: FixedProvider(.open), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .partialFailure)
        XCTAssertEqual(response.summary.failed, 1)
        XCTAssertEqual(response.summary.resumed, 0)

        // A denied session was never resumed — it must stay retryable.
        let ledger = ReplayLedger(fileURL: tempDir.appendingPathComponent("l.json"))
        let rescan = await SessionDiscovery().discover(configDirectory: tempDir.path, ledger: ledger)
        XCTAssertNil(rescan.first?.skipReason, "denied session must not be marked handled")
    }

    func testLockContentionNamesTheHolder() async throws {
        try writeBlockedSession()
        // Pre-hold the engine's lock file as a CLI-kind holder.
        let holder = WakeLock(
            lockURL: tempDir.appendingPathComponent("wake.lock"),
            legacyLockURLs: [],
            holderKind: .cli
        )
        XCTAssertEqual(holder.acquire(), .acquired)
        defer { holder.release() }

        let runner = RecordingRunner()
        let engine = makeEngine(provider: FixedProvider(.open), runner: runner)
        let response = await engine.run(provider: "claude", account: account(), dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .validationFailure)
        let message = try XCTUnwrap(response.message)
        XCTAssertTrue(message.contains("cli"), "message should name the holder kind: \(message)")
        XCTAssertTrue(message.contains("\(getpid())"), "message should name the holder pid: \(message)")
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty)
    }

    // MARK: - Outcome + JSON contract

    func testExitCodesAreDistinct() {
        let codes = [
            WakeCLIOutcome.success, .blockedWithoutWait, .quotaUnknown,
            .validationFailure, .partialFailure, .cancellation
        ].map(\.exitCode)
        XCTAssertEqual(Set(codes).count, codes.count, "Every outcome needs a distinct exit code")
        XCTAssertEqual(WakeCLIOutcome.success.exitCode, 0)
    }

    func testResponseJSONIsVersionedAndRoundTrips() throws {
        let response = WakeCLIResponse.from(
            candidates: [], outcome: .success, provider: "claude", dryRun: true, account: "/x/.claude"
        )
        let data = try response.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        let decoded = try JSONDecoder().decode(WakeCLIResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.schemaVersion, WakeCLIResponse.currentSchemaVersion)
    }
}

// MARK: - Doubles

private actor RecordingRunner: WakeExecuting {
    private(set) var ran: [String] = []
    private let outcome: WakeRunOutcome
    init(outcome: WakeRunOutcome = .succeeded) { self.outcome = outcome }
    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        ran.append(candidate.sessionID)
        return outcome
    }
}

private struct ThrowingProvider: WakeQuotaProviding {
    struct Boom: Error {}
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics { throw Boom() }
}

private struct FixedProvider: WakeQuotaProviding {
    enum Kind { case open, blocked }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
        let limit = kind == .open
            ? UsageLimit(used: 10, total: 100, resetTime: nil)
            : UsageLimit(used: 100, total: 100, resetTime: Date(timeIntervalSince1970: 9_999))
        return UsageMetrics(service: .claudeCode, sessionLimit: limit, lastUpdated: Date())
    }
}
