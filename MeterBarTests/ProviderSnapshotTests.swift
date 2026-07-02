import XCTest
@testable import MeterBar
import MeterBarShared

final class ProviderSnapshotTests: XCTestCase {
    private func makeMetrics(
        service: ServiceType,
        session: Double? = nil,
        weekly: Double? = nil,
        codeReview: Double? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            weeklyLimit: weekly.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            codeReviewLimit: codeReview.map { UsageLimit(used: $0, total: 100, resetTime: nil) }
        )
    }

    private func makeInput(
        metrics: [ServiceType: UsageMetrics] = [:],
        claudeAccounts: [ClaudeCodeAccount] = [.defaultAccount],
        claudeAccountMetrics: [UUID: UsageMetrics] = [:],
        enabledServices: Set<ServiceType> = Set(ServiceType.allCases)
    ) -> ProviderSnapshotBuilder.Input {
        ProviderSnapshotBuilder.Input(
            metrics: metrics,
            claudeAccounts: claudeAccounts,
            claudeAccountMetrics: claudeAccountMetrics,
            enabledServices: enabledServices
        )
    }

    // MARK: - Ordering and inclusion

    func testDisplayOrderIsCodexClaudeCursor() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                .claudeCode: makeMetrics(service: .claudeCode, weekly: 20),
                .cursor: makeMetrics(service: .cursor, weekly: 30)
            ]
        ))

        XCTAssertEqual(snapshots.map(\.service), [.codexCli, .claudeCode, .cursor])
        XCTAssertEqual(snapshots.map(\.title), ["Codex", "Claude", "Cursor"])
    }

    func testDisabledProvidersAreExcluded() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.cursor: makeMetrics(service: .cursor, weekly: 30)],
            enabledServices: [.cursor]
        ))

        XCTAssertEqual(snapshots.map(\.service), [.cursor])
    }

    func testProvidersWithoutMetricsAreIncludedForThePopoverAndFilterableForTheDashboard() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.cursor: makeMetrics(service: .cursor, weekly: 30)]
        ))

        // Popover shows all three (Codex/Claude as empty-state cards)…
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertFalse(snapshots[0].hasMetrics)
        // …the dashboard filters to providers with data.
        XCTAssertEqual(snapshots.filter(\.hasMetrics).map(\.service), [.cursor])
    }

    // MARK: - Claude accounts

    func testSingleDefaultClaudeAccountIsTitledClaude() {
        let accountMetrics = [ClaudeCodeAccount.defaultID: makeMetrics(service: .claudeCode, weekly: 40)]
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            claudeAccountMetrics: accountMetrics,
            enabledServices: [.claudeCode]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Claude"])
    }

    func testMultipleClaudeAccountsUseAccountNames() {
        let work = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let accounts = [ClaudeCodeAccount.defaultAccount, work]
        let accountMetrics = [
            ClaudeCodeAccount.defaultID: makeMetrics(service: .claudeCode, weekly: 40),
            work.id: makeMetrics(service: .claudeCode, weekly: 60)
        ]

        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            claudeAccounts: accounts,
            claudeAccountMetrics: accountMetrics,
            enabledServices: [.claudeCode]
        ))

        XCTAssertEqual(snapshots.map(\.title), [ClaudeCodeAccount.defaultAccount.name, "Work"])
        // Two accounts sharing a name must still produce distinct card ids.
        XCTAssertEqual(Set(snapshots.map(\.id)).count, snapshots.count)
    }

    // MARK: - Limits

    func testThirdLimitLabelIsSonnetForClaudeAndCodeReviewForCodex() {
        let claudeLimits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10),
            service: .claudeCode
        )
        let codexLimits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .codexCli, codeReview: 10),
            service: .codexCli
        )

        XCTAssertEqual(claudeLimits.map(\.title), ["Sonnet"])
        XCTAssertEqual(codexLimits.map(\.title), ["Code Review"])
    }

    func testPaceContextComesFromKindNotTitle() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, session: 10, weekly: 20, codeReview: 30),
            service: .claudeCode
        )

        XCTAssertEqual(limits.map(\.kind), [.session, .weekly, .codeReview])
        XCTAssertEqual(limits.map(\.paceContext), [.session, .weekly, .session])
    }

    func testPrimaryLimitIsTheTightestWindow() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(service: .codexCli, session: 91, weekly: 20),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .session)
        XCTAssertEqual(snapshot.band, .critical)
    }

    func testBandIsNilWithoutLimits() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: nil,
            emptyDetail: "Run codex login"
        )

        XCTAssertNil(snapshot.band)
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertFalse(snapshot.hasMetrics)
    }

    func testTightestLimitAcrossSnapshots() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 50),
                .cursor: makeMetrics(service: .cursor, weekly: 97)
            ],
            enabledServices: [.codexCli, .cursor]
        ))

        let tightest = snapshots.tightestLimit
        XCTAssertEqual(tightest?.percentLeft, 3)
        XCTAssertEqual(QuotaBand.forPercentLeft(tightest?.percentLeft ?? 100), .critical)
    }

    func testExhaustedLimitDetection() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 100, weekly: 20),
            emptyDetail: ""
        )

        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertEqual(snapshot.resetWindows.count, 2)
    }
}
