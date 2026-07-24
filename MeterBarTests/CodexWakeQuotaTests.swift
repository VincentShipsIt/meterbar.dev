import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// The Codex quota authority must fail closed exactly like the Claude one:
/// fetch error or stale reading ⇒ `.unknown`, fresh metrics classify normally.
final class CodexWakeQuotaTests: XCTestCase {
    private func account() -> CodexAccount { CodexAccount(id: UUID(), name: "a", homeDirectory: nil) }

    func testFetchFailureIsUnknown() async {
        let authority = WakeQuotaAuthority(provider: ThrowingCodexProvider(), maxAge: 3600, now: { Date() })
        let quota = await authority.freshQuota(account: account())
        guard case .unknown = quota else { return XCTFail("fetch failure must fail closed, got \(quota)") }
    }

    func testStaleMetricsAreUnknownNotAuthority() async {
        let stale = Date(timeIntervalSince1970: 0)
        let authority = WakeQuotaAuthority(
            provider: FixedCodexProvider(.open, lastUpdated: stale), maxAge: 120, now: { Date() }
        )
        let quota = await authority.freshQuota(account: account())
        guard case .unknown = quota else { return XCTFail("stale metrics must fail closed, got \(quota)") }
    }

    func testFreshOpenMetricsAreAvailable() async {
        let authority = WakeQuotaAuthority(provider: FixedCodexProvider(.open), maxAge: 3600, now: { Date() })
        let quota = await authority.freshQuota(account: account())
        XCTAssertEqual(quota, .available)
    }

    func testFreshBlockedMetricsAreBlocked() async {
        let authority = WakeQuotaAuthority(provider: FixedCodexProvider(.blocked), maxAge: 3600, now: { Date() })
        let quota = await authority.freshQuota(account: account())
        guard case .blocked = quota else { return XCTFail("maxed session window must block, got \(quota)") }
    }
}

// MARK: - Doubles

private struct ThrowingCodexProvider: WakeQuotaProviding {
    struct Boom: Error {}
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics { throw Boom() }
}

private struct FixedCodexProvider: WakeQuotaProviding {
    enum Kind { case open, blocked }
    let kind: Kind
    let lastUpdated: Date
    init(_ kind: Kind, lastUpdated: Date = Date()) { self.kind = kind; self.lastUpdated = lastUpdated }
    func fetchMetrics(account: CodexAccount) async throws -> UsageMetrics {
        let limit = kind == .open
            ? UsageLimit(used: 10, total: 100, resetTime: nil)
            : UsageLimit(used: 100, total: 100, resetTime: Date(timeIntervalSince1970: 9_999))
        return UsageMetrics(service: .codexCli, sessionLimit: limit, lastUpdated: lastUpdated)
    }
}
