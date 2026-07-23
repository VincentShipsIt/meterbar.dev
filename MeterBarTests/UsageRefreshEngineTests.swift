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
        ).run()

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
        let response = await makeEngine(refresh: { report }).run()

        XCTAssertEqual(response.outcome, .partialFailure)
        XCTAssertEqual(response.message?.contains("1 kept last-known-good"), true)
    }

    func testAllContactedProvidersFail() async {
        let report = makeReport([
            ProviderRefreshOutcome(provider: .cursor, state: .failed)
        ])
        let response = await makeEngine(refresh: { report }).run()

        XCTAssertEqual(response.outcome, .refreshFailed)
        XCTAssertEqual(response.outcome.exitCode, 13)
    }

    func testTimeoutReturnsBeforeUncooperativeRefreshAndKeepsLockHeld() async {
        let suspended = SuspendedRefresh()
        let lockURL = tempDirectory.appendingPathComponent("refresh.lock")
        let engine = makeEngine(
            lockURL: lockURL,
            timeout: 0.02,
            refresh: { await suspended.wait() }
        )

        let startedAt = Date()
        let response = await engine.run()
        XCTAssertEqual(response.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)

        let contender = WakeLock(lockURL: lockURL, legacyLockURLs: [], holderKind: .cli)
        guard case .contended = contender.acquire() else {
            return XCTFail("in-flight refresh must retain the lock after timeout")
        }

        await suspended.resume(makeReport([]))
        for _ in 0..<100 {
            if contender.acquire() == .acquired { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(contender.acquire(), .acquired)
        contender.release()
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
        ).run()

        XCTAssertEqual(response.outcome, .alreadyRunning)
        XCTAssertEqual(fetchCount.value, 0)
    }

    func testStaleCacheIsExplicitInJSON() async throws {
        let staleDate = Date().addingTimeInterval(-(ProviderParseHealthRecord.staleAfter + 1))
        let response = await makeEngine(
            refresh: { self.makeReport([]) },
            cache: [.cursor: metric(service: .cursor, lastUpdated: staleDate)]
        ).run()
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
        cache: [ServiceType: UsageMetrics] = [:]
    ) -> UsageRefreshEngine {
        UsageRefreshEngine(
            lock: WakeLock(
                lockURL: lockURL ?? tempDirectory.appendingPathComponent("refresh-\(UUID().uuidString).lock"),
                legacyLockURLs: [],
                holderKind: .cli
            ),
            timeout: timeout,
            refresh: refresh,
            cacheSnapshot: { cache }
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
