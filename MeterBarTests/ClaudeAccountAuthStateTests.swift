import SwiftUI
import XCTest
@testable import MeterBar
@testable import MeterBarShared

/// Per-account auth/error state (#292 phase 2).
///
/// The connection state used to be default-account-only, so a logged-out
/// secondary profile computed `needsLogin`, discarded it, fell back to its last
/// cached numbers, and rendered a green "Healthy" band. These tests pin the
/// three links of that chain: the resolver that turns one account's fetch
/// outcome into a state, the card-level notice that state maps onto, and the
/// presentation rule that must let the notice win over a stale band.
final class ClaudeAccountAuthStateTests: XCTestCase {
    private enum StubError: Error { case fetchFailed }

    // MARK: - ClaudeAccountStateResolver

    func testSuccessAdoptsTheSourceTheServiceReported() {
        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: .connected(.oauth),
                didSucceed: true,
                failure: nil,
                cachedLastUpdated: nil
            ),
            .connected(.oauth)
        )
        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: .connected(.cli),
                didSucceed: true,
                failure: nil,
                cachedLastUpdated: Date(timeIntervalSince1970: 1_000)
            ),
            .connected(.cli)
        )
    }

    func testSuccessWithoutAnAttributedSourceStillReadsAsConnected() {
        // A fetch that succeeded is a working profile even if the service never
        // recorded which source served it; "ready" is the honest neutral.
        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: nil,
                didSucceed: true,
                failure: nil,
                cachedLastUpdated: nil
            ),
            .cliAvailable
        )
    }

    /// The headline acceptance criterion: a logged-out account keeps its cached
    /// numbers, but the *state* must say Login required, not Stale.
    func testNeedsLoginWinsOverAStaleCache() {
        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: .needsLogin,
                didSucceed: false,
                failure: StubError.fetchFailed,
                cachedLastUpdated: Date(timeIntervalSince1970: 1_000)
            ),
            .needsLogin
        )
    }

    /// A missing CLI is not a stale reading — telling the user their data is
    /// merely old would hide the fact that nothing can refresh it.
    func testUnavailableWinsOverAStaleCache() {
        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: .unavailable,
                didSucceed: false,
                failure: StubError.fetchFailed,
                cachedLastUpdated: Date(timeIntervalSince1970: 1_000)
            ),
            .unavailable
        )
    }

    func testTransientFailureOverACachedReadingReportsStaleSinceThatReading() {
        let cachedAt = Date(timeIntervalSince1970: 1_720_000_000)

        XCTAssertEqual(
            ClaudeAccountStateResolver.state(
                serviceState: .connected(.oauth),
                didSucceed: false,
                failure: StubError.fetchFailed,
                cachedLastUpdated: cachedAt
            ),
            .stale(since: cachedAt)
        )
    }

    func testFailureWithoutAnyCacheReportsTheError() {
        let state = ClaudeAccountStateResolver.state(
            serviceState: nil,
            didSucceed: false,
            failure: StubError.fetchFailed,
            cachedLastUpdated: nil
        )

        guard case .error = state else {
            return XCTFail("A cold failure has nothing to call stale; expected .error, got \(state)")
        }
    }

    // MARK: - ProviderAuthNotice

    func testHealthyStatesCarryNoNotice() {
        XCTAssertNil(ProviderAuthNotice.forState(nil))
        XCTAssertNil(ProviderAuthNotice.forState(.connected(.oauth)))
        XCTAssertNil(ProviderAuthNotice.forState(.connected(.cli)))
        XCTAssertNil(ProviderAuthNotice.forState(.cliAvailable))
    }

    func testDegradedStatesMapOntoTheirNotice() {
        let staleSince = Date(timeIntervalSince1970: 1_720_000_000)

        XCTAssertEqual(ProviderAuthNotice.forState(.needsLogin), .loginRequired)
        XCTAssertEqual(ProviderAuthNotice.forState(.stale(since: staleSince)), .stale(since: staleSince))
        XCTAssertEqual(ProviderAuthNotice.forState(.error("boom")), .attention("boom"))
        XCTAssertEqual(ProviderAuthNotice.forState(.unavailable), .notConnected)
    }

    func testNoticeLabelsAreTheUserFacingWording() {
        XCTAssertEqual(ProviderAuthNotice.loginRequired.shortLabel, "Login required")
        XCTAssertEqual(ProviderAuthNotice.stale(since: Date()).shortLabel, "Stale")
        XCTAssertEqual(ProviderAuthNotice.attention("boom").shortLabel, "Needs attention")
        XCTAssertEqual(ProviderAuthNotice.notConnected.shortLabel, "Not connected")
    }

    // MARK: - Card presentation

    func testLoginRequiredBeatsAHealthyBandBuiltFromStaleCache() {
        let snapshot = makeSnapshot(sessionUsedPercent: 12, notice: .loginRequired)

        // The cached numbers are genuinely healthy — that is exactly the trap.
        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: snapshot), "Login required")
        XCTAssertNotEqual(ProviderCardPresentation.statusText(for: snapshot), QuotaBand.healthy.shortLabel)
        XCTAssertEqual(ProviderCardPresentation.statusColor(for: snapshot), MeterBarTheme.warning)
    }

    func testStaleNoticeSubduesTheBandInsteadOfColoringItGreen() {
        let snapshot = makeSnapshot(
            sessionUsedPercent: 12,
            notice: .stale(since: Date(timeIntervalSince1970: 1_720_000_000))
        )

        XCTAssertEqual(ProviderCardPresentation.statusText(for: snapshot), "Stale")
        XCTAssertEqual(ProviderCardPresentation.statusColor(for: snapshot), .secondary)
    }

    func testNoNoticeLeavesTheBandPresentationUntouched() {
        let snapshot = makeSnapshot(sessionUsedPercent: 12, notice: nil)

        XCTAssertEqual(ProviderCardPresentation.statusText(for: snapshot), QuotaBand.healthy.shortLabel)
        XCTAssertEqual(ProviderCardPresentation.statusColor(for: snapshot), QuotaBand.healthy.color)
    }

    func testAccessibilityLabelLeadsWithTheNoticeRatherThanTheBand() {
        let snapshot = makeSnapshot(sessionUsedPercent: 12, notice: .loginRequired)

        XCTAssertTrue(
            snapshot.accessibilityLabel.contains("Login required"),
            "VoiceOver must not read a stale band as Healthy: \(snapshot.accessibilityLabel)"
        )
        XCTAssertFalse(snapshot.accessibilityLabel.contains(QuotaBand.healthy.shortLabel))
    }

    // MARK: - Snapshot building

    func testLoggedOutCustomAccountKeepsItsNumbersAndCarriesTheLoginNotice() throws {
        let work = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let cached = UsageMetrics(
            service: .claudeCode,
            sessionLimit: UsageLimit(used: 12, total: 100, resetTime: nil)
        )

        let snapshots = ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: [:],
            claudeAccounts: [.defaultAccount, work],
            claudeAccountMetrics: [work.id: cached],
            enabledServices: [.claudeCode],
            claudeAccountStates: [
                ClaudeCodeAccount.defaultID: .connected(.oauth),
                work.id: .needsLogin
            ]
        ))

        let workCard = try XCTUnwrap(snapshots.first { $0.accountID == work.id })
        XCTAssertTrue(workCard.hasMetrics, "Last-known numbers must survive so the card can show them as stale")
        XCTAssertEqual(workCard.band, .healthy, "The band stays a pure function of the cached percentages")
        XCTAssertEqual(workCard.authNotice, .loginRequired)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: workCard), "Login required")

        let defaultCard = try XCTUnwrap(snapshots.first { $0.accountID == ClaudeCodeAccount.defaultID })
        XCTAssertNil(defaultCard.authNotice, "A connected profile must not inherit its neighbour's notice")
    }

    func testNonClaudeCardsNeverCarryANotice() throws {
        let snapshots = ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: [.cursor: UsageMetrics(
                service: .cursor,
                weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
            )],
            claudeAccounts: [.defaultAccount],
            claudeAccountMetrics: [:],
            enabledServices: [.cursor],
            claudeAccountStates: [ClaudeCodeAccount.defaultID: .needsLogin]
        ))

        let cursor = try XCTUnwrap(snapshots.first { $0.service == .cursor })
        XCTAssertNil(cursor.authNotice)
    }

    // MARK: - Stale login collapse (dashboard/popover one-liner)

    func testLoginRequiredCardCollapsesOnceItsCacheIsOlderThanTwoHours() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let threeHoursAgo = now.addingTimeInterval(-3 * 60 * 60)
        let card = makeCard(notice: .loginRequired, updatedAt: threeHoursAgo)

        XCTAssertTrue(ProviderCardPresentation.collapsesToLoginRow(snapshot: card, now: now))
    }

    func testLoginRequiredCardKeepsItsGaugesWhileTheCacheIsStillFresh() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let oneHourAgo = now.addingTimeInterval(-60 * 60)
        let card = makeCard(notice: .loginRequired, updatedAt: oneHourAgo)

        XCTAssertFalse(ProviderCardPresentation.collapsesToLoginRow(snapshot: card, now: now))
    }

    func testOnlyTheLoginNoticeCollapsesAnAgedCard() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)

        for notice: ProviderAuthNotice? in [nil, .stale(since: yesterday), .attention("boom"), .notConnected] {
            let card = makeCard(notice: notice, updatedAt: yesterday)
            XCTAssertFalse(
                ProviderCardPresentation.collapsesToLoginRow(snapshot: card, now: now),
                "\(String(describing: notice)) must not collapse to the login one-liner"
            )
        }
    }

    func testCardWithoutMetricsNeverCollapsesToTheLoginRow() {
        // No cache at all is the offline row's territory, not the login row's.
        let card = makeCard(notice: .loginRequired, updatedAt: nil)

        XCTAssertFalse(ProviderCardPresentation.collapsesToLoginRow(snapshot: card, now: Date()))
    }

    func testCollapsedLoginCardOffersNoDetailNavigation() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let collapsed = makeCard(notice: .loginRequired, updatedAt: now.addingTimeInterval(-3 * 60 * 60))
        let fresh = makeCard(notice: .loginRequired, updatedAt: now.addingTimeInterval(-60 * 60))

        XCTAssertFalse(
            ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: collapsed, now: now),
            "A collapsed login row is terminal; its stale detail would mislead"
        )
        XCTAssertTrue(
            ProviderCardPresentation.allowsDetailNavigation(hasSelectionHandler: true, snapshot: fresh, now: now),
            "A fresh login-required card keeps its recent detail reachable"
        )
    }

    // MARK: - Helpers

    private func makeCard(notice: ProviderAuthNotice?, updatedAt: Date?) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "claude-work-collapse",
            title: "Work",
            service: .claudeCode,
            updatedAt: updatedAt,
            limits: [
                SnapshotLimit(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usageLimit: UsageLimit(used: 12, total: 100, resetTime: nil)
                ),
            ],
            emptyDetail: "Run claude login",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: nil,
            authNotice: notice
        )
    }

    private func makeSnapshot(sessionUsedPercent: Double, notice: ProviderAuthNotice?) -> ProviderSnapshot {
        ProviderSnapshotBuilder.snapshot(
            title: "Work",
            service: .claudeCode,
            metrics: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(used: sessionUsedPercent, total: 100, resetTime: nil)
            ),
            emptyDetail: "Run claude login",
            accountID: UUID(),
            authNotice: notice
        )
    }
}
