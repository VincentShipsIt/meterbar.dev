import XCTest
@testable import MeterBar

final class ClaudeTokenRefresherTests: XCTestCase {
    private let account = ClaudeCodeAccount(
        id: UUID(),
        name: "Work",
        configDirectory: "/Users/tester/.claude-work"
    )
    private let now = Date(timeIntervalSince1970: 20_000)

    func testFingerprintChangeIsRequiredForSuccessfulRefresh() async throws {
        let before = keychainFingerprint(at: 100)
        let after = keychainFingerprint(at: 101)
        let fingerprints = LockedFingerprintSequence([before, after])
        let spawn = SpawnRecorder(result: .succeeded)
        let store = try makeStore()
        let refresher = makeRefresher(
            store: store,
            fingerprints: fingerprints,
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .background)

        XCTAssertEqual(result, .refreshed)
        XCTAssertEqual(spawn.callCount, 1)
        XCTAssertEqual(
            store.record(for: account.id),
            ClaudeRefreshCooldownRecord(outcome: .refreshed, completedAt: now)
        )

        let unchangedFingerprints = LockedFingerprintSequence([before, before])
        let unchangedSpawn = SpawnRecorder(result: .succeeded)
        let unchangedStore = try makeStore()
        let unchangedRefresher = makeRefresher(
            store: unchangedStore,
            fingerprints: unchangedFingerprints,
            spawn: unchangedSpawn
        )

        let unchangedResult = await unchangedRefresher.refresh(
            account: account,
            trigger: .background
        )

        XCTAssertEqual(unchangedResult, .inconclusive)
        XCTAssertEqual(
            unchangedStore.record(for: account.id),
            ClaudeRefreshCooldownRecord(outcome: .inconclusive, completedAt: now)
        )
    }

    func testNewFingerprintAfterMissingCredentialCountsAsRefreshed() async throws {
        let fingerprints = LockedFingerprintSequence([nil, keychainFingerprint(at: 100)])
        let spawn = SpawnRecorder(result: .succeeded)
        let refresher = makeRefresher(
            store: try makeStore(),
            fingerprints: fingerprints,
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .background)

        XCTAssertEqual(result, .refreshed)
    }

    func testCredentialDisappearanceDoesNotCountAsRefreshed() async throws {
        let fingerprints = LockedFingerprintSequence([keychainFingerprint(at: 100), nil])
        let spawn = SpawnRecorder(result: .succeeded)
        let refresher = makeRefresher(
            store: try makeStore(),
            fingerprints: fingerprints,
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .background)

        XCTAssertEqual(result, .inconclusive)
    }

    func testProcessFailureIsHardFailureWithoutPolling() async throws {
        let fingerprints = LockedFingerprintSequence([keychainFingerprint(at: 100)])
        let spawn = SpawnRecorder(result: .failed)
        let store = try makeStore()
        let refresher = makeRefresher(
            store: store,
            fingerprints: fingerprints,
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .background)

        XCTAssertEqual(result, .hardFailure)
        XCTAssertEqual(fingerprints.callCount, 1)
        XCTAssertEqual(
            store.record(for: account.id),
            ClaudeRefreshCooldownRecord(outcome: .hardFailure, completedAt: now)
        )
    }

    func testBackgroundRequestRespectsPersistedCooldown() async throws {
        let store = try makeStore()
        store.record(.inconclusive, for: account.id, at: now.addingTimeInterval(-10))
        let spawn = SpawnRecorder(result: .succeeded)
        let refresher = makeRefresher(
            store: store,
            fingerprints: LockedFingerprintSequence([]),
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .background)

        XCTAssertEqual(
            result,
            .cooldown(
                until: now.addingTimeInterval(10),
                previousOutcome: .inconclusive
            )
        )
        XCTAssertEqual(spawn.callCount, 0)
    }

    func testUserInitiatedRequestBypassesPersistedCooldown() async throws {
        let store = try makeStore()
        store.record(.hardFailure, for: account.id, at: now.addingTimeInterval(-10))
        let before = keychainFingerprint(at: 100)
        let after = keychainFingerprint(at: 101)
        let spawn = SpawnRecorder(result: .succeeded)
        let refresher = makeRefresher(
            store: store,
            fingerprints: LockedFingerprintSequence([before, after]),
            spawn: spawn
        )

        let result = await refresher.refresh(account: account, trigger: .userInitiated)

        XCTAssertEqual(result, .refreshed)
        XCTAssertEqual(spawn.callCount, 1)
    }

    func testConcurrentRequestsForSameAccountCoalesceToOneSpawn() async throws {
        let fingerprint = keychainFingerprint(at: 100)
        let gate = SpawnGate()
        let store = try makeStore()
        let refresher = ClaudeTokenRefresher(
            cooldownStore: store,
            fingerprint: { _ in fingerprint },
            runStatus: { _ in await gate.run() },
            sleep: { _ in },
            pollDelays: [0],
            now: { self.now }
        )

        let first = Task {
            await refresher.refresh(account: account, trigger: .background)
        }
        await poll(until: "the first attempt reaches the gate") {
            await gate.callCount > 0
        }
        let second = Task {
            await refresher.refresh(account: account, trigger: .userInitiated)
        }
        // The second refresh must have *joined* the in-flight attempt before
        // the gate opens. Releasing on a mere `Task` handle raced the
        // scheduler: when the first attempt finished before the second task's
        // `refresh` ran, the user-initiated call bypassed cooldown, spawned a
        // second run, and parked forever on the already-spent gate — the
        // silent `swift test` hang behind issue #319's CI cancellation.
        await poll(until: "the second refresh joins the in-flight attempt") {
            await refresher.coalescedJoins > 0
        }
        // Unconditional, including after a poll timeout: the gate latches open,
        // so releasing it is what lets both awaits below complete instead of
        // parking a failed run forever.
        await gate.release()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .inconclusive)
        XCTAssertEqual(secondResult, .inconclusive)
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
    }

    /// The guarantee `poll` exists to provide: a condition that never holds
    /// ends the wait with a named failure, not a spin that outlives the job.
    func testPollTimesOutInsteadOfSpinningForever() async {
        XCTExpectFailure("poll must report the timeout it is being asked for")
        let started = Date()
        await poll(0.2, until: "a condition that never holds") { false }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "poll must return at its deadline rather than spin"
        )
    }

    /// Deadline-bounded wait on actor-observable state, mirroring the
    /// `poll(_:until:)` idiom in `SessionWakeControllerTests`.
    ///
    /// Never spin unbounded here. `while !condition { await Task.yield() }`
    /// is the same defect this suite exists to pin: if the state never
    /// arrives, the loop burns a core until the CI job's 20-minute timeout
    /// kills the whole run, naming no test — precisely how issue #319 hid.
    /// A deadline turns that silent park into a named failure in seconds.
    private func poll(
        _ timeout: TimeInterval = 5,
        until description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () async -> Bool
    ) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail(
            "timed out after \(timeout)s waiting for \(description)",
            file: file,
            line: line
        )
    }

    private func makeRefresher(
        store: ClaudeRefreshCooldownStore,
        fingerprints: LockedFingerprintSequence,
        spawn: SpawnRecorder
    ) -> ClaudeTokenRefresher {
        ClaudeTokenRefresher(
            cooldownStore: store,
            fingerprint: { _ in fingerprints.next() },
            runStatus: { _ in spawn.run() },
            sleep: { _ in },
            pollDelays: [0],
            now: { self.now }
        )
    }

    private func makeStore() throws -> ClaudeRefreshCooldownStore {
        let suite = "ClaudeTokenRefresherTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ClaudeRefreshCooldownStore(userDefaults: defaults)
    }

    private func keychainFingerprint(at timestamp: TimeInterval) -> ClaudeCredentialFingerprint {
        .keychain(
            service: "Claude Code-credentials-c4394a73",
            modificationDate: Date(timeIntervalSince1970: timestamp)
        )
    }
}

nonisolated private final class LockedFingerprintSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClaudeCredentialFingerprint?]
    private var calls = 0

    init(_ values: [ClaudeCredentialFingerprint?]) {
        self.values = values
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> ClaudeCredentialFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

nonisolated private final class SpawnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: ClaudeStatusRunResult
    private var calls = 0

    init(result: ClaudeStatusRunResult) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run() -> ClaudeStatusRunResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return result
    }
}

private actor SpawnGate {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func run() async -> ClaudeStatusRunResult {
        callCount += 1
        if released {
            return .succeeded
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .succeeded
    }

    /// Latches open. Any `run()` that arrives after release — the misuse that
    /// previously parked the suite forever — returns immediately instead of
    /// storing a continuation nothing will ever resume.
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
