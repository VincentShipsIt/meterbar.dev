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
        grokAccounts: [GrokAccount] = [.defaultAccount],
        grokAccountMetrics: [UUID: UsageMetrics] = [:],
        claudeAccounts: [ClaudeCodeAccount] = [.defaultAccount],
        claudeAccountMetrics: [UUID: UsageMetrics] = [:],
        openRouterAccounts: [OpenRouterAccount] = [.defaultAccount],
        openRouterAccountMetrics: [UUID: UsageMetrics] = [:],
        enabledServices: Set<ServiceType> = Set(ServiceType.allCases),
        codexAccountAccess: [UUID: Bool] = [:],
        codexCliHasAccess: Bool = false
    ) -> ProviderSnapshotBuilder.Input {
        ProviderSnapshotBuilder.Input(
            metrics: metrics,
            codexAccounts: codexAccounts,
            codexAccountMetrics: codexAccountMetrics,
            codexAccountAccess: codexAccountAccess,
            grokAccounts: grokAccounts,
            grokAccountMetrics: grokAccountMetrics,
            claudeAccounts: claudeAccounts,
            claudeAccountMetrics: claudeAccountMetrics,
            enabledServices: enabledServices,
            codexCliHasAccess: codexCliHasAccess,
            openRouterAccounts: openRouterAccounts,
            openRouterAccountMetrics: openRouterAccountMetrics,
            openRouterAccountAccess: openRouterAccounts.reduce(into: [:]) {
                $0[$1.id] = true
            }
        )
    }

    // MARK: - Codex empty-state honesty (issue #304)

    /// A signed-in custom `CODEX_HOME` profile with no metrics yet is waiting on
    /// a refresh, not logged out — the card used to tell every custom profile to
    /// "Run codex login" because the check was gated on the default sentinel.
    func testConnectedCustomCodexProfileWaitsForRefreshInsteadOfAskingForLogin() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            codexAccounts: [work],
            enabledServices: [.codexCli],
            codexAccountAccess: [work.id: true]
        ))

        XCTAssertEqual(snapshots.map(\.emptyDetail), ["Waiting for refresh"])
    }

    func testLoggedOutCodexProfilesStillAskForLoginPerAccount() {
        let work = CodexAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/codex-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            codexAccounts: [.defaultAccount, work],
            enabledServices: [.codexCli],
            codexAccountAccess: [CodexAccount.defaultID: true, work.id: false],
            codexCliHasAccess: true
        ))

        XCTAssertEqual(snapshots.map(\.emptyDetail), ["Waiting for refresh", "Run codex login"])
    }

    // MARK: - Ordering and inclusion

    func testDisplayOrderIsAlphabeticalByVisibleLabels() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                .claudeCode: makeMetrics(service: .claudeCode, weekly: 20),
                .cursor: makeMetrics(service: .cursor, weekly: 30),
                .openRouter: makeMetrics(service: .openRouter, weekly: 40),
                .grok: makeMetrics(service: .grok, weekly: 50)
            ]
        ))

        XCTAssertEqual(
            snapshots.map(\.service),
            [.claudeCode, .codexCli, .cursor, .grok, .openRouter]
        )
        XCTAssertEqual(snapshots.map(\.title), ["Claude", "Codex", "Cursor", "Grok", "OpenRouter"])
    }

    /// Two accounts on one subscription stay adjacent even when their labels
    /// would otherwise split around another provider. The group sits where its
    /// earliest label belongs, then labels inside the group are alphabetical.
    func testDisplayOrderGroupsSubscriptionTypeThenSortsLabelsAlphabetically() {
        let personal = ClaudeCodeAccount(id: UUID(), name: "Personal", configDirectory: "/tmp/personal")
        let work = ClaudeCodeAccount(id: UUID(), name: "Work", configDirectory: "/tmp/work")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [
                .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                .cursor: makeMetrics(service: .cursor, weekly: 30)
            ],
            claudeAccounts: [work, personal],
            claudeAccountMetrics: [
                work.id: makeMetrics(service: .claudeCode, weekly: 20),
                personal.id: makeMetrics(service: .claudeCode, weekly: 40)
            ],
            enabledServices: [.codexCli, .claudeCode, .cursor]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Codex", "Cursor", "Personal", "Work"])
        XCTAssertEqual(snapshots.map(\.service), [.codexCli, .cursor, .claudeCode, .claudeCode])
    }

    func testDisplayOrderKeepsSameProviderAccountsTogetherWhenLabelsWouldOtherwiseSplit() {
        let alpha = ClaudeCodeAccount(id: UUID(), name: "alpha", configDirectory: "/tmp/alpha")
        let zLab = ClaudeCodeAccount(id: UUID(), name: "z-lab", configDirectory: "/tmp/z")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.codexCli: makeMetrics(service: .codexCli, weekly: 10)],
            claudeAccounts: [zLab, alpha],
            claudeAccountMetrics: [
                zLab.id: makeMetrics(service: .claudeCode, weekly: 20),
                alpha.id: makeMetrics(service: .claudeCode, weekly: 40)
            ],
            enabledServices: [.codexCli, .claudeCode]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["alpha", "z-lab", "Codex"])
        XCTAssertEqual(snapshots.map(\.service), [.claudeCode, .claudeCode, .codexCli])
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

    func testRenamedSoleDefaultAccountsUseConfiguredNames() {
        let codex = CodexAccount(
            id: CodexAccount.defaultID,
            name: "Codex Work",
            homeDirectory: nil
        )
        let claude = ClaudeCodeAccount(
            id: ClaudeCodeAccount.defaultID,
            name: "Claude Personal",
            configDirectory: nil
        )
        let grok = GrokAccount(
            id: GrokAccount.defaultID,
            name: "Grok Studio",
            homeDirectory: nil
        )

        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            codexAccounts: [codex],
            grokAccounts: [grok],
            claudeAccounts: [claude],
            enabledServices: [.codexCli, .claudeCode, .grok]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Claude Personal", "Codex Work", "Grok Studio"])
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

    func testMultipleGrokAccountsUseIndependentMetricsAndAccountNames() {
        let work = GrokAccount(id: UUID(), name: "Work", homeDirectory: "/tmp/grok-work")
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            grokAccounts: [.defaultAccount, work],
            grokAccountMetrics: [
                GrokAccount.defaultID: makeMetrics(service: .grok, weekly: 14),
                work.id: makeMetrics(service: .grok, weekly: 79)
            ],
            enabledServices: [.grok]
        ))

        XCTAssertEqual(snapshots.map(\.title), [GrokAccount.defaultName, "Work"])
        XCTAssertEqual(snapshots.map(\.accountID), [GrokAccount.defaultID, work.id])
        XCTAssertEqual(snapshots[0].primaryLimit?.usedPercent ?? 0, 14, accuracy: 0.001)
        XCTAssertEqual(snapshots[1].primaryLimit?.usedPercent ?? 0, 79, accuracy: 0.001)
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 2)
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

    // MARK: - Quota title routing

    /// The shared routing key each `(service, window, total)` triple resolves
    /// to, spelled out independently of `ServiceType` so a routing change has to
    /// be made deliberately in both places. Mirrors the widget-side table in
    /// `WidgetPresentationTests`.
    private func expectedQuotaTitleKey(
        service: ServiceType,
        kind: SnapshotLimit.Kind,
        limitTotal: Double,
        modelLimitLabel: String?
    ) -> ServiceType.QuotaTitleKey {
        let isIncludedPool = ServiceType.isCursorIncludedPool(total: limitTotal)
        switch kind {
        case .session:
            switch service {
            case .openRouter: return .keyLimit
            case .cursor: return isIncludedPool ? .cursorModels : .session
            case .claudeCode, .codexCli, .grok: return .session
            }
        case .weekly:
            switch service {
            case .openRouter: return .accountCredits
            case .cursor: return isIncludedPool ? .otherModels : .monthly
            case .claudeCode, .codexCli, .grok: return .weekly
            }
        case .codeReview:
            switch service {
            case .claudeCode: return .model(label: modelLimitLabel)
            case .cursor: return .onDemand
            case .codexCli, .openRouter, .grok: return .codeReview
            }
        case .additional:
            return .quota
        }
    }

    /// Every built limit carries the shared routing key, and its English title
    /// stays that key's English words. Localization switches over the key, so a
    /// limit whose key disagreed with the routing would translate as some other
    /// window without any English-language symptom.
    func testBuiltLimitsCarryTheSharedQuotaTitleRoutingKey() {
        for service in ServiceType.allCases {
            for total in [ServiceType.cursorIncludedPoolTotal, 500] {
                let metrics = UsageMetrics(
                    service: service,
                    sessionLimit: UsageLimit(used: 4, total: total, resetTime: nil),
                    weeklyLimit: UsageLimit(used: 64, total: total, resetTime: nil),
                    codeReviewLimit: UsageLimit(used: 12, total: total, resetTime: nil),
                    modelLimitLabel: service == .claudeCode ? "Fable" : nil
                )
                let limits = ProviderSnapshotBuilder.limits(for: metrics, service: service)
                XCTAssertEqual(limits.count, 3, "\(service) total \(total)")

                for limit in limits {
                    let expected = expectedQuotaTitleKey(
                        service: service,
                        kind: limit.kind,
                        limitTotal: total,
                        modelLimitLabel: metrics.modelLimitLabel
                    )
                    let context = "\(service) \(limit.id) total \(total)"
                    XCTAssertEqual(limit.quotaTitleKey, expected, context)
                    XCTAssertEqual(limit.title, expected.englishTitle, context)
                }
            }
        }
    }

    /// The parsed Claude model label is provider data: it stays verbatim in the
    /// English title and in the localized one, and only a missing label falls
    /// back to translated "Model" copy.
    func testClaudeModelWindowKeepsTheParsedLabelVerbatim() {
        let labeled = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10, modelLimitLabel: "Fable"),
            service: .claudeCode
        )
        XCTAssertEqual(labeled.map(\.quotaTitleKey), [.model(label: "Fable")])
        XCTAssertEqual(labeled.map(\.localizedTitle), ["Fable"])

        let unlabeled = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10),
            service: .claudeCode
        )
        XCTAssertEqual(unlabeled.map(\.quotaTitleKey), [.model(label: nil)])
    }

    /// Copy handed in directly — pseudo-localized layout fixtures, previews —
    /// is not routed, so it renders verbatim instead of being string-matched
    /// back onto a quota window.
    func testDirectlyTitledLimitIsNotRoutedThroughTheCatalog() {
        let limit = SnapshotLimit(
            id: "credits",
            kind: .weekly,
            title: "Credits",
            usageLimit: UsageLimit(used: 4, total: 10, resetTime: nil)
        )

        XCTAssertNil(limit.quotaTitleKey)
        XCTAssertEqual(limit.localizedTitle, "Credits")
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

    // Cursor's long window resets with `billingCycleEnd`. Percent-of-100 pools
    // match the dashboard's Cursor Models / Other Models bars; a request-count
    // grant keeps the legacy Monthly / Session labels.
    func testCursorPercentPoolsUseDashboardTitles() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .cursor, session: 4, weekly: 64),
            service: .cursor
        )

        XCTAssertEqual(limits.map(\.title), ["Cursor Models", "Other Models"])
        XCTAssertEqual(limits.map(\.id), ["session", "weekly"])
    }

    func testCursorLegacyRequestQuotaKeepsMonthlyLabel() {
        let metrics = UsageMetrics(
            service: .cursor,
            weeklyLimit: UsageLimit(used: 137, total: 500, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .cursor)

        XCTAssertEqual(limits.map(\.title), ["Monthly"])
    }

    func testCursorLegacyOnDemandKeepsSessionAndMonthlyLabels() {
        let metrics = UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(used: 4, total: 20, resetTime: nil),
            weeklyLimit: UsageLimit(used: 137, total: 500, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .cursor)

        XCTAssertEqual(limits.map(\.title), ["Session", "Monthly"])
    }

    func testCursorOnDemandWindowIsTitledOnDemand() {
        let metrics = UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(used: 4, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .cursor)

        XCTAssertEqual(limits.map(\.title), ["Cursor Models", "Other Models", "On-demand"])
    }

    func testCursorSinglePoolExhaustionDoesNotCollapseTheCard() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: makeMetrics(service: .cursor, session: 4, weekly: 100),
            emptyDetail: ""
        )

        // Spillover: the header must reflect the pool that still has room, not
        // the one that ran dry — Cursor is only "Out" when both are gone.
        XCTAssertEqual(snapshot.primaryLimit?.kind, .session)
        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
        XCTAssertFalse(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertTrue(snapshot.blockingLimits.isEmpty)
        XCTAssertEqual(snapshot.detailLimits.map(\.id), ["session", "weekly"])
    }

    func testCursorOtherModelsExhaustedStillReadsCursorModelsHeadroom() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: makeMetrics(service: .cursor, session: 27, weekly: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .session)
        XCTAssertEqual(snapshot.primaryLimit?.percentLeft, 73)
        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
    }

    func testCursorSpilloverBandTracksTheRoomiestPool() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: makeMetrics(service: .cursor, session: 100, weekly: 92),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.band, .critical)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
    }

    func testCursorLegacySinglePoolStillUsesTightestWindow() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: makeMetrics(service: .cursor, weekly: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertTrue(snapshot.hasExhaustedLimit)
    }

    func testCursorLegacyTwoWindowsKeepTheTightestWindowRule() {
        // Legacy Cursor payloads map an on-demand session limit plus a
        // request-count monthly quota — two provider-blocking windows that do
        // not share a budget, so neither spills into the other. Only the
        // percent-of-100 included pools do.
        let metrics = UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(used: 5, total: 50, resetTime: nil),
            weeklyLimit: UsageLimit(used: 500, total: 500, resetTime: nil),
            codeReviewLimit: nil
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: metrics,
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertEqual(snapshot.blockingLimits.map(\.kind), [.weekly])
    }

    func testCursorBothPoolsExhaustedBlocksTheProvider() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .cursor,
            metrics: makeMetrics(service: .cursor, session: 100, weekly: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertTrue(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertEqual(Set(snapshot.blockingLimits.map(\.kind)), [.session, .weekly])
    }

    func testPaceContextComesFromKindNotTitle() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, session: 10, weekly: 20, codeReview: 30),
            service: .claudeCode
        )

        XCTAssertEqual(limits.map(\.kind), [.session, .weekly, .codeReview])
        XCTAssertEqual(limits.map(\.paceContext), [.session, .weekly, .session])
    }

    /// Cursor's included pools now carry `periodKind: .monthly` (for the
    /// cadence-title headline) but `paceContext` still switches on `kind`, so
    /// pace copy for the session/weekly slots must stay byte-identical.
    func testPaceContextIgnoresPeriodKindForSessionAndWeeklySlots() {
        let metrics = makeMetrics(service: .cursor, session: 10, weekly: 20)
        let monthlyMetrics = UsageMetrics(
            service: .cursor,
            sessionLimit: UsageLimit(
                used: 10,
                total: ServiceType.cursorIncludedPoolTotal,
                resetTime: metrics.sessionLimit?.resetTime,
                periodKind: .monthly
            ),
            weeklyLimit: UsageLimit(
                used: 20,
                total: ServiceType.cursorIncludedPoolTotal,
                resetTime: metrics.weeklyLimit?.resetTime,
                periodKind: .monthly
            )
        )

        let limits = ProviderSnapshotBuilder.limits(for: monthlyMetrics, service: .cursor)

        XCTAssertEqual(limits.map(\.kind), [.session, .weekly])
        XCTAssertEqual(limits.map(\.paceContext), [.session, .weekly])
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

    func testGrokMonthlyWeeklySlotIsTitledMonthlyNeverWeekly() {
        let metrics = UsageMetrics(
            service: .grok,
            weeklyLimit: UsageLimit(used: 41, total: 100, resetTime: nil, periodKind: .monthly)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .grok)
        let weekly = try? XCTUnwrap(limits.first { $0.id == "weekly" })

        XCTAssertEqual(weekly?.quotaTitleKey, .monthly)
        XCTAssertEqual(weekly?.title, "Monthly")
        XCTAssertEqual(weekly?.localizedTitle, "Monthly")
        XCTAssertFalse(weekly?.title.contains("Weekly") == true)
    }

    func testAdditionalLimitsBecomeExtraSnapshotRows() {
        let metrics = UsageMetrics(
            service: .grok,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, periodKind: .session),
            weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil, periodKind: .weekly),
            additionalLimits: [
                UsageLimit(used: 30, total: 100, resetTime: nil, periodKind: .daily),
                UsageLimit(used: 40, total: 100, resetTime: nil, periodKind: .billing),
                UsageLimit(used: 50, total: 100, resetTime: nil, periodKind: .unknown)
            ]
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .grok)

        XCTAssertEqual(limits.map(\.id), ["session", "weekly", "additional-0", "additional-1", "additional-2"])
        XCTAssertEqual(limits.map(\.quotaTitleKey), [.session, .weekly, .daily, .billingCycle, .quota])
        XCTAssertEqual(limits.map(\.title), ["Session", "Weekly", "Daily", "Billing cycle", "Quota"])
        XCTAssertEqual(limits.last?.localizedTitle, "Quota")
    }
}
