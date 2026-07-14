import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Coverage for #96: the cancellable watcher state machine and its
/// fresh-quota-before-every-launch contract.
final class WakeCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var accountDir: URL!
    private var ledgerURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WakeCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        accountDir = tempDir.appendingPathComponent("account")
        ledgerURL = tempDir.appendingPathComponent("ledger.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    /// Write `count` blocked transcripts with existing cwds ⇒ executable.
    private func writeBlockedSessions(_ count: Int) throws {
        let projects = accountDir.appendingPathComponent("projects").appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        for index in 0..<count {
            let object: [String: Any] = [
                "type": "assistant",
                "timestamp": "2026-07-10T02:00:0\(index).000Z",
                "isApiErrorMessage": true,
                "apiErrorStatus": 429,
                "cwd": tempDir.path, // exists ⇒ executable
                "sessionId": "s\(index)",
                "message": ["role": "assistant", "content": [["type": "text", "text": "session limit resets 3:00am (UTC)"]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let line = String(decoding: data, as: UTF8.self)
            try line.write(to: projects.appendingPathComponent("s\(index).jsonl"), atomically: true, encoding: .utf8)
        }
    }

    private func account() -> ClaudeCodeAccount {
        ClaudeCodeAccount(id: UUID(), name: "test", configDirectory: accountDir.path)
    }

    private func makeCoordinator(
        provider: WakeQuotaProviding,
        runner: WakeExecuting,
        bounds: WakeBounds = WakeBounds.default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) -> WakeCoordinator {
        WakeCoordinator(
            discovery: SessionDiscovery(),
            authority: WakeQuotaAuthority(provider: provider, maxAge: 3600, now: { Date() }),
            runner: runner,
            ledger: ReplayLedger(fileURL: ledgerURL),
            bounds: bounds,
            now: { Date() },
            sleep: sleep
        )
    }

    private let immediateSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

    // MARK: - Tests

    func testAvailableRunsWholeQueueAndCompletes() async throws {
        try writeBlockedSessions(2)
        let runner = RecordingRunner()
        let provider = SequencedProvider(repeating: .open)
        let coordinator = makeCoordinator(provider: provider, runner: runner, sleep: immediateSleep)

        await coordinator.start(account: account())
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertEqual(Set(ran), ["s0", "s1"])
        if case let .completed(summary) = await coordinator.state {
            XCTAssertEqual(summary.resumed, 2)
            XCTAssertEqual(summary.remaining, 0)
        } else {
            XCTFail("Expected completed state")
        }
        // Fresh quota before each of 2 launches + one post-attempt re-check.
        let calls = await provider.calls
        XCTAssertGreaterThanOrEqual(calls, 3)
    }

    func testStartWithRuntimeDrivesTheWholeQueue() async throws {
        // The provider-agnostic entry point: arm with an explicit runtime rather
        // than the Claude `start(account:)` facade. Same lifecycle, driven off
        // `WakeProviderRuntime` (discover / freshQuota / makeRunner).
        try writeBlockedSessions(2)
        let runner = RecordingRunner()
        let provider = SequencedProvider(repeating: .open)
        let coordinator = makeCoordinator(provider: provider, runner: runner, sleep: immediateSleep)
        let runtime = ClaudeWakeRuntime(
            account: account(),
            discovery: SessionDiscovery(),
            authority: WakeQuotaAuthority(provider: provider, maxAge: 3600, now: { Date() }),
            makeRunner: { _ in runner }
        )

        await coordinator.start(runtime: runtime)
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertEqual(Set(ran), ["s0", "s1"])
        if case let .completed(summary) = await coordinator.state {
            XCTAssertEqual(summary.resumed, 2)
            XCTAssertEqual(summary.remaining, 0)
        } else {
            XCTFail("Expected completed state")
        }
    }

    func testUnknownQuotaLaunchesNothing() async throws {
        try writeBlockedSessions(1)
        let runner = RecordingRunner()
        let provider = SequencedProvider(repeating: .fail)
        let bounds = WakeBounds(
            pollInterval: 1, bufferAfterReset: 0, gapBetweenSessions: 0,
            perSessionTimeout: 60, maxTurns: 10, maxSessionsPerRun: 5, maxUnknownPolls: 3
        )
        let coordinator = makeCoordinator(provider: provider, runner: runner, bounds: bounds, sleep: immediateSleep)

        await coordinator.start(account: account())
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty)
        if case .failed = await coordinator.state {} else {
            XCTFail("Expected failed after exhausting unknown polls")
        }
    }

    func testWeeklyBlockDefersLaunchThenRunsWhenOpen() async throws {
        try writeBlockedSessions(1)
        let runner = RecordingRunner()
        // First reading blocked, then open.
        let provider = SequencedProvider(steps: [.blocked(nil)], repeating: .open)
        let coordinator = makeCoordinator(provider: provider, runner: runner, sleep: immediateSleep)

        await coordinator.start(account: account())
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertEqual(ran, ["s0"])
        let history = await coordinator.stateHistory
        let waitedBeforeRunning = history.firstIndex(where: { if case .waiting = $0 { return true }; return false })
        let firstRunning = history.firstIndex(where: { if case .running = $0 { return true }; return false })
        XCTAssertNotNil(waitedBeforeRunning)
        XCTAssertNotNil(firstRunning)
        XCTAssertLessThan(waitedBeforeRunning!, firstRunning!)
    }

    func testReMaxedQuotaStopsQueueThenPreservesRemainingForLater() async throws {
        try writeBlockedSessions(2)
        let runner = RecordingRunner()
        // Open → (after first attempt) blocked ⇒ queue pauses → open ⇒ resumes.
        // The block between the two launches proves the queue is not drained
        // blindly: it stops and the remaining session is preserved for later.
        let provider = SequencedProvider(steps: [.open, .blocked(nil), .open], repeating: .open)
        let coordinator = makeCoordinator(provider: provider, runner: runner, sleep: immediateSleep)

        await coordinator.start(account: account())
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertEqual(Set(ran), ["s0", "s1"], "Both run, but only after the queue paused on re-exhaustion")
        XCTAssertEqual(ran.count, 2)

        // Assert ordering: running(s0) → waiting → running(s1).
        let history = await coordinator.stateHistory
        var sawFirstRun = false
        var sawWaitAfterFirst = false
        var waitPrecededSecondRun = false
        for state in history {
            switch state {
            case .running where !sawFirstRun:
                sawFirstRun = true
            case .waiting where sawFirstRun:
                sawWaitAfterFirst = true
            case .running where sawWaitAfterFirst:
                waitPrecededSecondRun = true
            default:
                break
            }
        }
        XCTAssertTrue(waitPrecededSecondRun, "Re-exhaustion must pause the queue before resuming remaining work")
    }

    func testStopCancelsPendingSleepDeterministically() async throws {
        try writeBlockedSessions(1)
        let runner = RecordingRunner()
        let provider = SequencedProvider(repeating: .blocked(nil))
        // Real (long) sleep so the loop parks in `.waiting` until cancelled.
        let coordinator = makeCoordinator(
            provider: provider,
            runner: runner,
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        )

        await coordinator.start(account: account())
        try? await Task.sleep(nanoseconds: 80_000_000) // let it reach `.waiting`
        await coordinator.stop()
        await coordinator.waitUntilFinished()

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .off)
        let ran = await runner.ran
        XCTAssertTrue(ran.isEmpty, "No session should launch while blocked")
    }

    func testActiveChildCancellationPreservesCandidateAndDoesNotRecord() async throws {
        try writeBlockedSessions(1)
        let runner = CancellingRunner()
        let provider = SequencedProvider(repeating: .open)
        // Real sleep so cancellation must actually unwind the running child.
        let coordinator = makeCoordinator(
            provider: provider,
            runner: runner,
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        )

        await coordinator.start(account: account())

        // Wait until the child is actually running before we stop the watcher.
        var running = false
        for _ in 0..<200 {
            if case .running = await coordinator.state { running = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(running, "A session should be running before we cancel")

        await coordinator.stop()
        await coordinator.waitUntilFinished()

        let ran = await runner.ran
        XCTAssertEqual(ran, ["s0"], "The candidate should have been attempted exactly once")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .off, "Cancelling mid-child settles the watcher to off")

        // The interrupted block must NOT be recorded, so a later run rediscovers
        // it as an executable candidate rather than skipping it as handled.
        let ledger = ReplayLedger(fileURL: ledgerURL)
        let candidates = await SessionDiscovery().discover(configDirectory: accountDir.path, ledger: ledger)
        XCTAssertEqual(candidates.first?.sessionID, "s0")
        XCTAssertNil(candidates.first?.skipReason, "Interrupted candidate must stay retryable")
        XCTAssertTrue(candidates.first?.isExecutable ?? false)
    }

    func testSuccessfulResumeIsRecordedInLedger() async throws {
        try writeBlockedSessions(1)
        let runner = RecordingRunner(outcome: .succeeded)
        let provider = SequencedProvider(repeating: .open)
        let coordinator = makeCoordinator(provider: provider, runner: runner, sleep: immediateSleep)

        await coordinator.start(account: account())
        await coordinator.waitUntilFinished()

        // A fresh discovery now sees the block as already handled.
        let ledger = ReplayLedger(fileURL: ledgerURL)
        let candidates = await SessionDiscovery().discover(configDirectory: accountDir.path, ledger: ledger)
        XCTAssertEqual(candidates.first?.skipReason, .alreadyHandled)
    }
}

// MARK: - Test doubles

private actor RecordingRunner: WakeExecuting {
    private(set) var ran: [String] = []
    private let outcome: WakeRunOutcome
    init(outcome: WakeRunOutcome = .succeeded) { self.outcome = outcome }
    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        ran.append(candidate.sessionID)
        return outcome
    }
}

/// Blocks inside `run` until the surrounding structured task is cancelled, then
/// reports `.cancelled` — mirroring a real child that honors cooperative
/// cancellation when the watcher is stopped mid-run.
private actor CancellingRunner: WakeExecuting {
    private(set) var ran: [String] = []
    func run(_ candidate: WakeSessionCandidate, bounds: WakeBounds) async -> WakeRunOutcome {
        ran.append(candidate.sessionID)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return .cancelled
    }
}

private actor SequencedProvider: WakeQuotaProviding {
    enum Step { case open, blocked(Date?), fail }
    struct Boom: Error {}

    private var steps: [Step]
    private let repeatingStep: Step
    private(set) var calls = 0

    init(steps: [Step] = [], repeating repeatingStep: Step) {
        self.steps = steps
        self.repeatingStep = repeatingStep
    }

    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics {
        calls += 1
        let step = steps.isEmpty ? repeatingStep : steps.removeFirst()
        switch step {
        case .open:
            return UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil),
                lastUpdated: Date()
            )
        case let .blocked(reset):
            return UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: 100, total: 100, resetTime: reset),
                lastUpdated: Date()
            )
        case .fail:
            throw Boom()
        }
    }
}
