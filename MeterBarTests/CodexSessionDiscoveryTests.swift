import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// End-to-end Codex discovery over a synthetic `~/.codex/sessions` tree, plus
/// the engine driving a `CodexWakeRuntime` through to a resume.
final class CodexSessionDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home = home.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixture writing

    private func jsonl(_ objects: [[String: Any]]) -> String {
        objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    @discardableResult
    private func writeRollout(
        id: String,
        cwd: String?,
        reached: Any = "primary",
        day: String = "2026/07/13",
        completed: Bool = false
    ) throws -> URL {
        let dir = home.appendingPathComponent("sessions/\(day)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta: [String: Any] = ["id": id, "source": "exec"]
        if let cwd { meta["cwd"] = cwd }
        var objects: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-07-13T09:00:00.000Z", "payload": meta],
            ["type": "event_msg", "timestamp": "2026-07-13T09:05:00.000Z",
             "payload": ["type": "token_count",
                         "rate_limits": ["rate_limit_reached_type": reached,
                                         "primary": ["resets_at": 1_900_000_000]]]]
        ]
        if completed {
            objects.append(["type": "event_msg", "timestamp": "2026-07-13T09:06:00.000Z",
                            "payload": ["type": "task_complete"]])
        }
        let url = dir.appendingPathComponent("rollout-2026-07-13T09-00-00-\(id).jsonl")
        try jsonl(objects).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func ledger() -> ReplayLedger {
        ReplayLedger(fileURL: home.appendingPathComponent("ledger.json"))
    }

    // MARK: - Discovery

    func testDiscoversExecutableBlockedSession() async throws {
        try writeRollout(id: "s-exec", cwd: home.path)
        let candidates = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: ledger())
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.provider, .codex)
        XCTAssertEqual(candidate.sessionID, "s-exec")
        XCTAssertEqual(candidate.reason, .sessionLimit)
        XCTAssertTrue(candidate.isExecutable)
        XCTAssertEqual(candidate.resetHint?.resetAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testMissingWorkingDirectoryIsSkipNotDrop() async throws {
        try writeRollout(id: "s-dead", cwd: "/no/such/dir/\(UUID().uuidString)")
        let candidates = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: ledger())
        XCTAssertEqual(candidates.first?.skipReason, .missingWorkingDirectory)
        XCTAssertFalse(candidates.first?.isExecutable ?? true)
    }

    func testCompletedSessionIsNotDiscovered() async throws {
        try writeRollout(id: "s-done", cwd: home.path, completed: true)
        let candidates = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: ledger())
        XCTAssertTrue(candidates.isEmpty, "a recovered session is not a wake target")
    }

    func testNormalUsageSessionIsNotDiscovered() async throws {
        try writeRollout(id: "s-ok", cwd: home.path, reached: NSNull())
        let candidates = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: ledger())
        XCTAssertTrue(candidates.isEmpty)
    }

    func testAlreadyHandledBlockIsFlaggedAcrossRescan() async throws {
        try writeRollout(id: "s-dup", cwd: home.path)
        let led = ledger()
        let first = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: led)
        let fingerprint = try XCTUnwrap(first.first?.fingerprint)
        await led.record(fingerprint)

        let rescan = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: led)
        XCTAssertEqual(rescan.first?.skipReason, .alreadyHandled)
    }

    func testDiscoveryIsScopedToTheSelectedHome() async throws {
        // A blocked rollout under a DIFFERENT home must never be seen.
        let other = home.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let dir = other.appendingPathComponent("sessions/2026/07/13")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jsonl([["type": "session_meta", "timestamp": "2026-07-13T09:00:00.000Z",
                    "payload": ["id": "elsewhere", "cwd": home.path]],
                   ["type": "event_msg", "timestamp": "2026-07-13T09:05:00.000Z",
                    "payload": ["type": "token_count", "rate_limits": ["rate_limit_reached_type": "primary"]]]])
            .write(to: dir.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)

        let candidates = await CodexSessionDiscovery().discover(codexHome: home.path, ledger: ledger())
        XCTAssertTrue(candidates.isEmpty, "discovery must only read the selected CODEX_HOME")
    }

    // MARK: - Engine integration through the runtime

    func testEngineResumesCodexSessionWhenQuotaAvailable() async throws {
        try writeRollout(id: "s-run", cwd: home.path)
        let runner = CodexRecordingRunner(outcome: .succeeded)
        let runtime = CodexWakeRuntime(
            account: CodexAccount(id: UUID(), name: "a", homeDirectory: home.path),
            discovery: CodexSessionDiscovery(),
            authority: WakeQuotaAuthority(provider: OpenCodexProvider(), maxAge: 3600, now: { Date() }),
            makeRunner: { _ in runner }
        )
        let engine = WakeCLIEngine(
            ledgerFactory: { self.ledger() },
            lock: WakeLock(lockURL: home.appendingPathComponent("wake.lock"), legacyLockURLs: [])
        )
        let response = await engine.run(runtime: runtime, dryRun: false, limit: nil)
        XCTAssertEqual(response.outcome, .success)
        XCTAssertEqual(response.provider, "codex")
        XCTAssertEqual(response.summary.resumed, 1)
        let ran = await runner.ran
        XCTAssertEqual(ran, ["s-run"])
    }

    func testEngineDryRunForCodexLaunchesNothing() async throws {
        try writeRollout(id: "s-dry", cwd: home.path)
        let runner = CodexRecordingRunner(outcome: .succeeded)
        let runtime = CodexWakeRuntime(
            account: CodexAccount(id: UUID(), name: "a", homeDirectory: home.path),
            authority: WakeQuotaAuthority(provider: ThrowingCodexProvider2()),
            makeRunner: { _ in runner }
        )
        let engine = WakeCLIEngine(
            ledgerFactory: { self.ledger() },
            lock: WakeLock(lockURL: home.appendingPathComponent("wake.lock"), legacyLockURLs: [])
        )
        let response = await engine.run(runtime: runtime, dryRun: true, limit: nil)
        XCTAssertEqual(response.outcome, .success)
        XCTAssertTrue(response.dryRun)
        XCTAssertEqual(response.eligibleCount, 1)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty, "dry-run must launch nothing and never consult quota")
    }
}

// MARK: - Doubles

private actor CodexRecordingRunner: WakeExecuting {
    private(set) var ran: [String] = []
    private let outcome: WakeRunOutcome
    init(outcome: WakeRunOutcome = .succeeded) { self.outcome = outcome }
    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        ran.append(candidate.sessionID)
        return outcome
    }
}

private struct OpenCodexProvider: WakeQuotaProviding {
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics {
        UsageMetrics(service: .codexCli, sessionLimit: UsageLimit(used: 5, total: 100, resetTime: nil), lastUpdated: Date())
    }
}

private struct ThrowingCodexProvider2: WakeQuotaProviding {
    struct Boom: Error {}
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics { throw Boom() }
}
