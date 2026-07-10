import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Coverage for #96: the fresh, fail-closed quota gate and the validated
/// numeric bounds.
final class WakeQuotaGateTests: XCTestCase {
    private func metrics(
        session: UsageLimit?,
        weekly: UsageLimit? = nil,
        codeReview: UsageLimit? = nil,
        updated: Date = Date()
    ) -> UsageMetrics {
        UsageMetrics(
            service: .claudeCode,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: codeReview,
            lastUpdated: updated
        )
    }

    private func open(_ reset: Date? = nil) -> UsageLimit {
        UsageLimit(used: 10, total: 100, resetTime: reset)
    }

    private func maxed(_ reset: Date?) -> UsageLimit {
        UsageLimit(used: 100, total: 100, resetTime: reset)
    }

    // MARK: - Classification

    func testAllOpenIsAvailable() {
        XCTAssertEqual(WakeQuota.classify(metrics(session: open())), .available)
    }

    func testSessionMaxedIsBlocked() {
        let reset = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(WakeQuota.classify(metrics(session: maxed(reset))), .blocked(until: reset, reason: .sessionLimit))
    }

    func testWeeklyMaxedBlocksEvenWhenSessionOpen() {
        let reset = Date(timeIntervalSince1970: 9_000)
        let quota = WakeQuota.classify(metrics(session: open(), weekly: maxed(reset)))
        XCTAssertEqual(quota, .blocked(until: reset, reason: .weeklyLimit))
    }

    func testMissingSessionWindowFailsClosed() {
        guard case .unknown = WakeQuota.classify(metrics(session: nil)) else {
            return XCTFail("Missing session window must be unknown, not available")
        }
    }

    func testAvailableDoesNotAllowLaunchWhenBlockedOrUnknown() {
        XCTAssertTrue(WakeQuota.available.allowsLaunch)
        XCTAssertFalse(WakeQuota.blocked(until: nil, reason: .sessionLimit).allowsLaunch)
        XCTAssertFalse(WakeQuota.unknown(reason: "x").allowsLaunch)
    }

    // MARK: - Authority (fail-closed)

    func testFetchFailureIsUnknown() async {
        let authority = WakeQuotaAuthority(provider: ThrowingProvider())
        let quota = await authority.freshQuota(account: .defaultAccount)
        guard case .unknown = quota else { return XCTFail("Fetch failure must fail closed") }
    }

    func testStaleMetricsAreUnknownNotAuthority() async {
        let stale = metrics(session: open(), updated: Date(timeIntervalSince1970: 0))
        let authority = WakeQuotaAuthority(
            provider: StaticProvider(stale),
            maxAge: 120,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        guard case .unknown = await authority.freshQuota(account: .defaultAccount) else {
            return XCTFail("Stale metrics must not be treated as authority")
        }
    }

    func testFreshMetricsClassify() async {
        let fresh = metrics(session: open(), updated: Date(timeIntervalSince1970: 9_950))
        let authority = WakeQuotaAuthority(
            provider: StaticProvider(fresh),
            maxAge: 120,
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let quota = await authority.freshQuota(account: .defaultAccount)
        XCTAssertEqual(quota, .available)
    }

    // MARK: - Bounds

    func testBoundsClampOutOfRangeValues() {
        let bounds = WakeBounds(
            pollInterval: 1,          // below min 15
            bufferAfterReset: -50,    // below min 0
            gapBetweenSessions: 5_000, // above max 600
            perSessionTimeout: 5,     // below min 60
            maxTurns: 9_999,          // above max 200
            maxSessionsPerRun: 0,     // below min 1 — never unlimited
            maxUnknownPolls: 0
        )
        XCTAssertEqual(bounds.pollInterval, 15)
        XCTAssertEqual(bounds.bufferAfterReset, 0)
        XCTAssertEqual(bounds.gapBetweenSessions, 600)
        XCTAssertEqual(bounds.perSessionTimeout, 60)
        XCTAssertEqual(bounds.maxTurns, 200)
        XCTAssertEqual(bounds.maxSessionsPerRun, 1)
        XCTAssertEqual(bounds.maxUnknownPolls, 1)
    }

    func testDefaultBoundsAreConservativeAndNotUnlimited() {
        XCTAssertLessThanOrEqual(WakeBounds.default.maxSessionsPerRun, 100)
        XCTAssertGreaterThanOrEqual(WakeBounds.default.maxSessionsPerRun, 1)
        XCTAssertGreaterThan(WakeBounds.default.maxTurns, 0)
        XCTAssertGreaterThan(WakeBounds.default.perSessionTimeout, 0)
    }
}

// MARK: - Providers

private struct ThrowingProvider: WakeQuotaProviding {
    struct Boom: Error {}
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics { throw Boom() }
}

private struct StaticProvider: WakeQuotaProviding {
    let metrics: UsageMetrics
    init(_ metrics: UsageMetrics) { self.metrics = metrics }
    func fetchMetrics(account: ClaudeCodeAccount) async throws -> UsageMetrics { metrics }
}
