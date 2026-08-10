import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

final class UsageRefreshEngineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageRefreshEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    func testSuccessReportsProviderStateAndFreshCache() async throws {
        let now = Date()
        let report = makeReport([
            ProviderRefreshOutcome(provider: .codexCli, state: .refreshed, lastUpdated: now)
        ])
        let response = await makeEngine(
            refresh: { report },
            cache: [.codexCli: metric(service: .codexCli, lastUpdated: now)]
        ).run().response

        XCTAssertEqual(response.outcome, .success)
        let object = try jsonObject(response)
        XCTAssertEqual(object["outcome"] as? String, "success")
        let providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.first?["provider"] as? String, "codex")
        XCTAssertEqual(providers.first?["state"] as? String, "refreshed")
        let cache = try XCTUnwrap(object["cache"] as? [String: Any])
        XCTAssertEqual(cache["isStale"] as? Bool, false)
    }

    func testPartialFailurePreservesCachedProvider() async {
        let report = makeReport([
            ProviderRefreshOutcome(provider: .cursor, state: .refreshed),
            ProviderRefreshOutcome(provider: .codexCli, state: .failed, servedFromCache: true)
        ])
        let response = await makeEngine(refresh: { report }).run().response

        XCTAssertEqual(response.outcome, .partialFailure)
        XCTAssertEqual(response.message?.contains("1 kept last-known-good"), true)
    }

    func testAllContactedProvidersFail() async {
        let report = makeReport([
            ProviderRefreshOutcome(provider: .cursor, state: .failed)
        ])
        let response = await makeEngine(refresh: { report }).run().response

        XCTAssertEqual(response.outcome, .refreshFailed)
        XCTAssertEqual(response.outcome.exitCode, 13)
    }

    func testTimeoutReturnsBeforeUncooperativeRefreshAndKeepsLockHeld() async throws {
        let suspended = SuspendedRefresh()
        let lockURL = tempDirectory.appendingPathComponent("refresh.lock")
        let engine = makeEngine(
            lockURL: lockURL,
            timeout: 0.02,
            refresh: { await suspended.wait() }
        )

        let startedAt = Date()
        let outcome = await engine.run()
        XCTAssertEqual(outcome.response.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)

        // The lock is released by the handed-back cleanup task, not by process
        // death: a caller that keeps running must be able to await it.
        let cleanup = try XCTUnwrap(
            outcome.pendingCleanup,
            "a timeout with work still in flight must hand back a cleanup handle"
        )

        let contender = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .cli)
        guard case .contended = contender.acquire() else {
            return XCTFail("in-flight refresh must retain the lock after timeout")
        }

        await suspended.resume(makeReport([]))
        await cleanup.value
        XCTAssertEqual(contender.acquire(), .acquired)
        contender.release()
    }

    func testCompletedRefreshNeedsNoCleanupBecauseTheLockIsAlreadyReleased() async {
        let lockURL = tempDirectory.appendingPathComponent("refresh.lock")
        let outcome = await makeEngine(lockURL: lockURL, refresh: { self.makeReport([]) }).run()

        XCTAssertNil(outcome.pendingCleanup)
        let contender = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .cli)
        XCTAssertEqual(contender.acquire(), .acquired)
        contender.release()
    }

    func testCooperativeCancellationReportsTheDocumentedCancellationOutcome() async {
        let suspended = SuspendedRefresh()
        let outcome = await makeEngine(
            timeout: 10,
            refresh: { await suspended.wait() },
            shouldCancel: { true }
        ).run()

        XCTAssertEqual(outcome.response.outcome, .cancellation)
        XCTAssertEqual(outcome.response.outcome.exitCode, 130)
        await suspended.resume(makeReport([]))
        await outcome.pendingCleanup?.value
    }

    /// The CLI emits its JSON before waiting, so the wait must be bounded: an
    /// uncooperative provider cannot hold the process open indefinitely.
    func testAwaitPendingCleanupGivesUpAtItsCeiling() async {
        let stuck = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { stuck.cancel() }
        let result = UsageRefreshCLI.Result(
            jsonOutput: "{}",
            summaryLine: "",
            message: nil,
            exitCode: 0,
            pendingCleanup: stuck
        )

        let startedAt = Date()
        await result.awaitPendingCleanup(timeout: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testAwaitPendingCleanupReturnsImmediatelyWhenNothingIsInFlight() async {
        let result = UsageRefreshCLI.Result(
            jsonOutput: "{}",
            summaryLine: "",
            message: nil,
            exitCode: 0,
            pendingCleanup: nil
        )
        await result.awaitPendingCleanup(timeout: 30)
    }

    func testConcurrentRefreshFailsSafelyWithoutFetching() async {
        let lockURL = tempDirectory.appendingPathComponent("refresh.lock")
        let holder = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .app)
        XCTAssertEqual(holder.acquire(), .acquired)
        defer { holder.release() }

        let fetchCount = LockedCounter()
        let response = await makeEngine(
            lockURL: lockURL,
            refresh: {
                fetchCount.increment()
                return self.makeReport([])
            }
        ).run().response

        XCTAssertEqual(response.outcome, .alreadyRunning)
        XCTAssertEqual(fetchCount.value, 0)
    }

    func testStaleCacheIsExplicitInJSON() async throws {
        let staleDate = Date().addingTimeInterval(-(ProviderParseHealthRecord.staleAfter + 1))
        let response = await makeEngine(
            refresh: { self.makeReport([]) },
            cache: [.cursor: metric(service: .cursor, lastUpdated: staleDate)]
        ).run().response
        let object = try jsonObject(response)
        let cache = try XCTUnwrap(object["cache"] as? [String: Any])

        XCTAssertEqual(cache["isStale"] as? Bool, true)
        XCTAssertNotNil(cache["ageSeconds"])
    }

    func testExitCodesAreDistinct() {
        let outcomes: [RefreshCLIOutcome] = [
            .success, .alreadyRunning, .timedOut, .partialFailure, .refreshFailed, .cancellation
        ]
        XCTAssertEqual(Set(outcomes.map(\.exitCode)).count, outcomes.count)
        XCTAssertEqual(RefreshCLIOutcome.success.exitCode, 0)
        XCTAssertEqual(RefreshCLIOutcome.cancellation.exitCode, 130)
    }

    private func makeEngine(
        lockURL: URL? = nil,
        timeout: TimeInterval = 1,
        refresh: @escaping UsageRefreshEngine.RefreshOperation,
        cache: [ServiceType: UsageMetrics] = [:],
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> UsageRefreshEngine {
        UsageRefreshEngine(
            lock: WakeLock(
                lockURL: lockURL ?? tempDirectory.appendingPathComponent("refresh-\(UUID().uuidString).lock"),
                legacyLockURLs: [],
                holderKind: .cli
            ),
            timeout: timeout,
            refresh: refresh,
            cacheSnapshot: { cache },
            shouldCancel: shouldCancel
        )
    }

    private func makeReport(_ outcomes: [ProviderRefreshOutcome]) -> UsageRefreshReport {
        let now = Date()
        return UsageRefreshReport(startedAt: now, finishedAt: now, outcomes: outcomes)
    }

    private func metric(service: ServiceType, lastUpdated: Date) -> UsageMetrics {
        UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(used: 1, total: 100, resetTime: nil),
            lastUpdated: lastUpdated
        )
    }

    private func jsonObject(_ response: RefreshCLIResponse) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any]
        )
    }
}

private actor SuspendedRefresh {
    private var continuation: CheckedContinuation<UsageRefreshReport, Never>?
    private var pendingReport: UsageRefreshReport?

    func wait() async -> UsageRefreshReport {
        if let pendingReport {
            self.pendingReport = nil
            return pendingReport
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ report: UsageRefreshReport) {
        guard let continuation else {
            pendingReport = report
            return
        }
        self.continuation = nil
        continuation.resume(returning: report)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
