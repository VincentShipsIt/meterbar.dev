import XCTest
@testable import MeterBar
import MeterBarShared

final class ProviderSnapshotTests: XCTestCase {
    private func makeMetrics(
        service: ServiceType,
        session: Double? = nil,
        weekly: Double? = nil,
        codeReview: Double? = nil,
        extraUsage: ExtraUsageStatus? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            weeklyLimit: weekly.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            codeReviewLimit: codeReview.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            extraUsage: extraUsage
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

    func testDisplayOrderIsCodexClaudeCursorOpenRouter() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                .claudeCode: makeMetrics(service: .claudeCode, weekly: 20),
                .cursor: makeMetrics(service: .cursor, weekly: 30),
                .openRouter: makeMetrics(service: .openRouter, weekly: 40)
            ]
        ))

        XCTAssertEqual(snapshots.map(\.service), [.codexCli, .claudeCode, .cursor, .openRouter])
        XCTAssertEqual(snapshots.map(\.title), ["Codex", "Claude", "Cursor", "OpenRouter"])
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

        // Popover shows all enabled providers (Codex/Claude/OpenRouter as empty-state cards)…
        XCTAssertEqual(snapshots.count, 4)
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

    func testDisabledClaudeAccountsAreExcludedEvenWithCachedMetrics() {
        let disabled = ClaudeCodeAccount(
            id: UUID(),
            name: "Disabled",
            configDirectory: "/tmp/disabled",
            isEnabled: false
        )
        let enabled = ClaudeCodeAccount(id: UUID(), name: "Enabled", configDirectory: "/tmp/enabled")
        let accountMetrics = [
            disabled.id: makeMetrics(service: .claudeCode, weekly: 80),
            enabled.id: makeMetrics(service: .claudeCode, weekly: 20)
        ]

        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            claudeAccounts: [disabled, enabled],
            claudeAccountMetrics: accountMetrics,
            enabledServices: [.claudeCode]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Enabled"])
        XCTAssertEqual(snapshots.first?.limits.first?.usageLimit.used, 20)
    }

    func testClaudeProviderHasNoSnapshotWhenAllAccountsAreDisabled() {
        let disabledDefault = ClaudeCodeAccount(
            id: ClaudeCodeAccount.defaultID,
            name: ClaudeCodeAccount.defaultName,
            configDirectory: nil,
            isEnabled: false
        )

        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.claudeCode: makeMetrics(service: .claudeCode, weekly: 90)],
            claudeAccounts: [disabledDefault],
            enabledServices: [.claudeCode]
        ))

        XCTAssertTrue(snapshots.isEmpty)
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

    func testOpenRouterUsesCurrencyCreditLabels() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .openRouter, session: 10, weekly: 20),
            service: .openRouter
        )

        XCTAssertEqual(limits.map(\.title), ["Key limit", "Account credits"])
        XCTAssertTrue(limits.allSatisfy { $0.valueStyle == .currency })
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
        XCTAssertEqual(snapshot.resetWindows.map(\.title), ["Session"])
    }

    func testWeeklyExhaustionIsDistinctFromSessionExhaustion() {
        let weeklyOut = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 0, weekly: 100),
            emptyDetail: ""
        )
        let sessionOut = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(service: .codexCli, session: 100, weekly: 0),
            emptyDetail: ""
        )

        XCTAssertTrue(weeklyOut.hasExhaustedLimit)
        XCTAssertTrue(weeklyOut.hasExhaustedWeeklyLimit)
        XCTAssertTrue(sessionOut.hasExhaustedLimit)
        XCTAssertFalse(sessionOut.hasExhaustedWeeklyLimit)
    }

    func testSecondaryQuotaExhaustionDoesNotBlockProvider() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(
                service: .codexCli,
                session: 20,
                weekly: 30,
                codeReview: 100,
                extraUsage: ExtraUsageStatus(state: .off)
            ),
            emptyDetail: ""
        )

        XCTAssertFalse(snapshot.hasExhaustedLimit)
        XCTAssertFalse(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertTrue(snapshot.blockingLimits.isEmpty)
        XCTAssertTrue(snapshot.resetWindows.isEmpty)
        XCTAssertEqual(snapshot.detailLimits.map(\.id), ["session", "weekly", "codeReview"])
        XCTAssertNotNil(snapshot.displayedExtraUsage)
        XCTAssertTrue(ProviderStatusBadges(snapshot: snapshot).hasContent)
    }

    func testConfirmedExtraUsageKeepsExhaustedPrimaryWindowNonblocking() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(
                service: .codexCli,
                session: 100,
                weekly: 20,
                extraUsage: ExtraUsageStatus(state: .on, detail: "$5.00 in credits")
            ),
            emptyDetail: ""
        )

        XCTAssertFalse(snapshot.hasExhaustedLimit)
        XCTAssertTrue(snapshot.blockingLimits.isEmpty)
        XCTAssertTrue(snapshot.resetWindows.isEmpty)
        XCTAssertEqual(snapshot.displayedExtraUsage?.state, .on)
    }

    func testPrimaryExhaustionStillBlocksWhenExtraUsageIsOff() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(
                service: .codexCli,
                session: 100,
                weekly: 20,
                extraUsage: ExtraUsageStatus(state: .off)
            ),
            emptyDetail: ""
        )

        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertEqual(snapshot.blockingLimits.map(\.kind), [.session])
        XCTAssertEqual(snapshot.resetWindows.map(\.title), ["Session"])
        XCTAssertTrue(
            ProviderStatusBadges(snapshot: snapshot).hasContent,
            "Overage On/Off remains relevant when the subscription quota is exhausted."
        )
    }

    func testEstimatedExhaustionDoesNotClaimProviderIsBlocked() {
        let metrics = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(
                used: 500,
                total: 500,
                resetTime: nil,
                isEstimated: true
            )
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: metrics,
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
        XCTAssertFalse(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertTrue(snapshot.blockingLimits.isEmpty)
    }

    func testBlockingResetWindowsExcludeSimultaneouslyExhaustedSecondaryQuota() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 100, weekly: 30, codeReview: 100),
            emptyDetail: ""
        )

        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertEqual(snapshot.blockingLimits.map(\.kind), [.session])
        XCTAssertEqual(snapshot.resetWindows.map(\.title), ["Session"])
    }

    func testDetailLimitsHideSessionWhenWeeklyIsExhausted() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 0, weekly: 100, codeReview: 40),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.limits.map(\.id), ["session", "weekly", "codeReview"])
        XCTAssertEqual(snapshot.detailLimits.map(\.id), ["weekly", "codeReview"])
    }

    func testDetailLimitsKeepSessionWhenOnlySessionIsExhausted() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: makeMetrics(service: .codexCli, session: 100, weekly: 25),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.detailLimits.map(\.id), ["session", "weekly"])
    }
}
