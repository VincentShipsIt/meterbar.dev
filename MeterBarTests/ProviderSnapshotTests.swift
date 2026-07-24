import XCTest
@testable import MeterBar
import MeterBarShared

final class ProviderSnapshotTests: XCTestCase {
    private func makeMetrics(
        service: ServiceType,
        session: Double? = nil,
        weekly: Double? = nil,
        codeReview: Double? = nil,
        modelLimitLabel: String? = nil,
        extraUsage: ExtraUsageStatus? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            weeklyLimit: weekly.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            codeReviewLimit: codeReview.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            modelLimitLabel: modelLimitLabel,
            extraUsage: extraUsage
        )
    }

    private func makeInput(
        metrics: [ServiceType: UsageMetrics] = [:],
        codexAccounts: [CodexAccount] = [.defaultAccount],
        codexAccountMetrics: [UUID: UsageMetrics] = [:],
        claudeAccounts: [ClaudeCodeAccount] = [.defaultAccount],
        claudeAccountMetrics: [UUID: UsageMetrics] = [:],
        fableSessions: [ClaudeFableSession] = [],
        enabledServices: Set<ServiceType> = Set(ServiceType.allCases)
    ) -> ProviderSnapshotBuilder.Input {
        ProviderSnapshotBuilder.Input(
            metrics: metrics,
            codexAccounts: codexAccounts,
            codexAccountMetrics: codexAccountMetrics,
            claudeAccounts: claudeAccounts,
            claudeAccountMetrics: claudeAccountMetrics,
            fableSessions: fableSessions,
            enabledServices: enabledServices
        )
    }

    // MARK: - Ordering and inclusion

    func testDisplayOrderIsCodexClaudeCursorOpenRouterGrok() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                .claudeCode: makeMetrics(service: .claudeCode, weekly: 20),
                .cursor: makeMetrics(service: .cursor, weekly: 30),
                .openRouter: makeMetrics(service: .openRouter, weekly: 40),
                .grok: makeMetrics(service: .grok, weekly: 50)
            ]
        ))

        XCTAssertEqual(snapshots.map(\.service), [.codexCli, .claudeCode, .cursor, .openRouter, .grok])
        XCTAssertEqual(snapshots.map(\.title), ["Codex", "Claude", "Cursor", "OpenRouter", "Grok"])
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

        // Popover shows all enabled providers (Codex/Claude/OpenRouter/Grok as empty-state cards)…
        XCTAssertEqual(snapshots.count, 5)
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

    func testClaudeSnapshotsCarryOnlyTheirAccountFableActivity() {
        let now = Date()
        let work = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            claudeAccounts: [.defaultAccount, work],
            claudeAccountMetrics: [
                ClaudeCodeAccount.defaultID: makeMetrics(service: .claudeCode, weekly: 40),
                work.id: makeMetrics(service: .claudeCode, weekly: 60)
            ],
            fableSessions: [
                ClaudeFableSession(
                    sourceSessionID: "default-session",
                    accountID: ClaudeCodeAccount.defaultID,
                    accountName: ClaudeCodeAccount.defaultName,
                    model: "claude-fable-5",
                    firstObservedAt: now.addingTimeInterval(-180),
                    lastObservedAt: now.addingTimeInterval(-60),
                    state: .completed
                ),
                ClaudeFableSession(
                    sourceSessionID: "work-session",
                    accountID: work.id,
                    accountName: work.name,
                    model: "claude-fable-5",
                    firstObservedAt: now.addingTimeInterval(-120),
                    lastObservedAt: now,
                    state: .active
                )
            ],
            enabledServices: [.claudeCode]
        ))

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].fableActivity?.session?.sourceSessionID, "default-session")
        XCTAssertEqual(snapshots[1].fableActivity?.session?.sourceSessionID, "work-session")
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

    func testMultipleCodexAccountsUseIndependentMetricsAndAccountNames() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: [:],
            codexAccounts: [.defaultAccount, work],
            codexAccountMetrics: [
                CodexAccount.defaultID: makeMetrics(service: .codexCli, weekly: 25),
                work.id: makeMetrics(service: .codexCli, weekly: 75)
            ],
            claudeAccounts: [.defaultAccount],
            claudeAccountMetrics: [:],
            enabledServices: [.codexCli]
        ))

        XCTAssertEqual(snapshots.map(\.title), [CodexAccount.defaultName, "Work"])
        XCTAssertEqual(snapshots.map(\.accountID), [CodexAccount.defaultID, work.id])
        XCTAssertEqual(snapshots.map { $0.primaryLimit?.usedPercent }, [25, 75])
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 2)
    }

    func testDisabledCodexAccountsAreExcludedEvenWithCachedMetrics() {
        let disabled = CodexAccount(
            id: UUID(),
            name: "Disabled",
            homeDirectory: "/tmp/codex-disabled",
            isEnabled: false
        )
        let enabled = CodexAccount(id: UUID(), name: "Enabled", homeDirectory: "/tmp/codex-enabled")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            codexAccounts: [disabled, enabled],
            codexAccountMetrics: [
                disabled.id: makeMetrics(service: .codexCli, weekly: 80),
                enabled.id: makeMetrics(service: .codexCli, weekly: 20)
            ],
            enabledServices: [.codexCli]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Enabled"])
        XCTAssertEqual(snapshots.first?.limits.first?.usageLimit.used, 20)
    }

    func testDefaultCodexAccountDoesNotBorrowAnotherEnabledAccountsMetrics() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let workMetrics = makeMetrics(service: .codexCli, weekly: 75)
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.codexCli: workMetrics],
            codexAccounts: [.defaultAccount, work],
            codexAccountMetrics: [work.id: workMetrics],
            enabledServices: [.codexCli]
        ))

        XCTAssertEqual(snapshots.map(\.title), [CodexAccount.defaultName, "Work"])
        XCTAssertFalse(snapshots[0].hasMetrics)
        XCTAssertEqual(snapshots[1].primaryLimit?.usedPercent, 75)
    }

    func testSoleDefaultCodexAccountDoesNotBorrowAggregateWhileAnotherAccountCacheExists() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let workMetrics = makeMetrics(service: .codexCli, weekly: 75)
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.codexCli: workMetrics],
            codexAccounts: [.defaultAccount],
            codexAccountMetrics: [work.id: workMetrics],
            enabledServices: [.codexCli]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Codex"])
        XCTAssertFalse(snapshots[0].hasMetrics)
    }

    func testCodexProviderHasNoSnapshotWhenAllAccountsAreDisabled() {
        let disabledDefault = CodexAccount(
            id: CodexAccount.defaultID,
            name: CodexAccount.defaultName,
            homeDirectory: nil,
            isEnabled: false
        )
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.codexCli: makeMetrics(service: .codexCli, weekly: 90)],
            codexAccounts: [disabledDefault],
            enabledServices: [.codexCli]
        ))

        XCTAssertTrue(snapshots.isEmpty)
    }

    func testStatusItemPinOptionsUseStableProviderAccountWindowKeys() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: [:],
            codexAccounts: [work],
            codexAccountMetrics: [
                work.id: makeMetrics(service: .codexCli, session: 25, weekly: 75)
            ],
            claudeAccounts: [.defaultAccount],
            claudeAccountMetrics: [:],
            enabledServices: [.codexCli]
        ))

        XCTAssertEqual(
            snapshots.statusItemPinOptions,
            [
                StatusItemPinOption(
                    id: StatusItemPinKey.make(service: .codexCli, accountID: work.id, windowID: "session"),
                    title: "Work · Session"
                ),
                StatusItemPinOption(
                    id: StatusItemPinKey.make(service: .codexCli, accountID: work.id, windowID: "weekly"),
                    title: "Work · Weekly"
                )
            ]
        )
    }

    // MARK: - Limits

    func testThirdLimitUsesReportedClaudeModelLabelAndCodeReviewForCodex() {
        let claudeLimits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10, modelLimitLabel: "Fable"),
            service: .claudeCode
        )
        let codexLimits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .codexCli, codeReview: 10),
            service: .codexCli
        )

        XCTAssertEqual(claudeLimits.map(\.title), ["Fable"])
        XCTAssertEqual(codexLimits.map(\.title), ["Code Review"])
    }

    func testLegacyClaudeModelLimitUsesNeutralLabel() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10),
            service: .claudeCode
        )

        XCTAssertEqual(limits.map(\.title), ["Model"])
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

    func testModelScopedExhaustionDoesNotMarkProviderOut() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 16, weekly: 71, codeReview: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertEqual(snapshot.limits.last?.percentLeft, 0)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
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

    func testTightestLimitIgnoresModelScopedExhaustion() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .claudeCode: makeMetrics(
                    service: .claudeCode,
                    session: 16,
                    weekly: 71,
                    codeReview: 100,
                    modelLimitLabel: "Sonnet"
                ),
                .cursor: makeMetrics(service: .cursor, weekly: 80)
            ],
            enabledServices: [.claudeCode, .cursor]
        ))

        XCTAssertEqual(snapshots.tightestLimit?.percentLeft, 20)
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

    func testDetailLimitsKeepOnlyWeeklyWhenWeeklyIsExhausted() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Claude",
            service: .claudeCode,
            metrics: makeMetrics(service: .claudeCode, session: 0, weekly: 100, codeReview: 40),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.limits.map(\.id), ["session", "weekly", "codeReview"])
        XCTAssertEqual(snapshot.detailLimits.map(\.id), ["weekly"])
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
