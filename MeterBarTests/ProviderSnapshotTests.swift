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

    func testCredentialFailureSuppressesResetCountdownWithoutDiscardingCachedQuota() throws {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: Date(timeIntervalSince1970: 1_900_000_000))
        )
        var snapshot = ProviderSnapshotBuilder.snapshot(
            title: "xAI", service: .xai, metrics: metrics, emptyDetail: "", authNotice: nil
        )
        XCTAssertFalse(snapshot.resetWindows.isEmpty)
        for notice in [ProviderAuthNotice.loginRequired, .attention("Credential access failed"), .notConnected] {
            snapshot.authNotice = notice
            XCTAssertFalse(snapshot.showsQuotaReset)
            XCTAssertTrue(snapshot.resetWindows.isEmpty)
            XCTAssertTrue(snapshot.hasExhaustedLimit)
            XCTAssertEqual(snapshot.limits.count, 1)
        }
        snapshot.authNotice = nil
        snapshot.issues = ProviderReadinessEvaluator.cursor(CursorReadinessInput(
            isInstalled: true, database: .needsKeychainAccess, now: Date(timeIntervalSince1970: 1_800_000_000)
        )).checks.filter { $0.level == .fail }
        XCTAssertFalse(snapshot.showsQuotaReset)
        XCTAssertTrue(snapshot.resetWindows.isEmpty)
    }

    func testTokenOnlyProvidersUseKeyNoticesWhileKimiKeepsLoginGuidance() throws {
        for service in [ServiceType.zaiCodingPlan, .githubCopilot, .kimiCode] {
            for rejected in [false, true] {
                var input = makeInput(
                    metrics: [service: makeMetrics(service: service, session: 20)],
                    enabledServices: [service]
                )
                if rejected {
                    input.lastErrors.simpleProviders[service] = .notAuthenticated
                } else {
                    input.simpleProviderAccess[service] = false
                }
                let snapshot = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(input).first)
                XCTAssertEqual(snapshot.authNotice, service == .kimiCode ? .loginRequired : .notConnected)
                XCTAssertNil(snapshot.accountID)
            }
        }
    }

    func testCopilotBudgetSnapshotIsCurrencyAndEmptyStatesInventNoQuota() throws {
        let metrics = UsageMetrics(
            service: .githubCopilot,
            sessionLimit: UsageLimit(used: 12, total: 30, resetTime: nil, periodKind: .monthly)
        )
        let snapshot = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.githubCopilot: metrics], enabledServices: [.githubCopilot]
        )).first)
        XCTAssertEqual(snapshot.limits.count, 1)
        XCTAssertEqual(snapshot.limits.first?.valueStyle, .currency)
        XCTAssertNil(snapshot.accountID)
        let empty = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.githubCopilot: UsageMetrics(service: .githubCopilot)], enabledServices: [.githubCopilot]
        )).first)
        XCTAssertTrue(empty.limits.isEmpty)
    }

    @MainActor
    func testConnectedIdleMuseCardSaysIdleAndExplainsMissingQuota() throws {
        var input = makeInput(
            metrics: [.museCode: UsageMetrics(service: .museCode)],
            enabledServices: [.museCode]
        )
        input.simpleProviderAccess[.museCode] = true
        input.simpleProviderNotes[.museCode] = MuseCodeCopy.idle
        input.planLabels[.museCode] = "High Usage"
        let snapshot = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(input).first)
        XCTAssertFalse(snapshot.hasMetrics)
        XCTAssertTrue(snapshot.limits.isEmpty, "An idle answer must not invent a percentage")
        XCTAssertNil(snapshot.authNotice)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: snapshot), "Idle")
        XCTAssertEqual(ProviderCardHeader.Content(snapshot: snapshot).statusText, "Idle")
        XCTAssertEqual(ProviderCardHeader.Content(snapshot: snapshot).subtitle, MuseCodeCopy.idle)
        XCTAssertEqual(ProviderCardHeader.Content(snapshot: snapshot).planLabel, "High Usage")
        XCTAssertTrue(snapshot.accessibilityLabel.contains("Idle"))
        XCTAssertTrue(PopoverOverviewPanel.errorSnapshots(in: [snapshot]).isEmpty)
    }

    @MainActor
    func testIdleMuseNoteDoesNotMaskALaterRefreshFailure() throws {
        var input = makeInput(enabledServices: [.museCode])
        input.simpleProviderAccess[.museCode] = true
        input.simpleProviderNotes[.museCode] = MuseCodeCopy.idle
        input.lastErrors.simpleProviders[.museCode] = .apiError("HTTP 503")
        let snapshot = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(input).first)
        XCTAssertNil(snapshot.emptyStatusLabel)
        XCTAssertNotEqual(ProviderCardPresentation.statusText(for: snapshot), "Idle")
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
                .xai: makeMetrics(service: .xai, weekly: 30),
                .openRouter: makeMetrics(service: .openRouter, weekly: 40),
                .kimiCode: makeMetrics(service: .kimiCode, weekly: 60),
                .zaiCodingPlan: makeMetrics(service: .zaiCodingPlan, weekly: 70),
                .githubCopilot: makeMetrics(service: .githubCopilot, weekly: 80),
                .museCode: makeMetrics(service: .museCode, weekly: 85),
                .claudePlatform: makeMetrics(service: .claudePlatform, weekly: 15)
            ]
        ))

        XCTAssertEqual(
            snapshots.map(\.service),
            [
                .claudeCode, .codexCli, .claudePlatform, .githubCopilot, .kimiCode, .museCode,
                .openRouter, .xai, .zaiCodingPlan
            ]
        )
        XCTAssertEqual(
            snapshots.map(\.title),
            ["Claude", "Codex", "Console", "Copilot", "Kimi", "Muse", "OpenRouter", "xAI", "Z.ai"]
        )
    }

    func testFreshnessNoteOverridesTheUpdatedStampWhileBarsRemain() throws {
        let note = "Window idle, usage not reported. As of 2026-10-13 12:00 UTC."
        var input = makeInput(
            metrics: [.museCode: makeMetrics(service: .museCode, session: 21)],
            enabledServices: [.museCode]
        )
        input.simpleProviderFreshness[.museCode] = note
        let snapshot = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(input).first)
        XCTAssertEqual(snapshot.updatedText, note)
        XCTAssertTrue(snapshot.hasMetrics)

        var empty = makeInput(enabledServices: [.museCode])
        empty.simpleProviderFreshness[.museCode] = note
        let blank = try XCTUnwrap(ProviderSnapshotBuilder.snapshots(empty).first { $0.service == .museCode })
        XCTAssertNotEqual(blank.updatedText, note)
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
                .xai: makeMetrics(service: .xai, weekly: 30)
            ],
            claudeAccounts: [work, personal],
            claudeAccountMetrics: [
                work.id: makeMetrics(service: .claudeCode, weekly: 20),
                personal.id: makeMetrics(service: .claudeCode, weekly: 40)
            ],
            enabledServices: [.codexCli, .claudeCode, .xai]
        ))

        XCTAssertEqual(snapshots.map(\.title), ["Codex", "Personal", "Work", "xAI"])
        XCTAssertEqual(snapshots.map(\.service), [.codexCli, .claudeCode, .claudeCode, .xai])
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
            metrics: [.xai: makeMetrics(service: .xai, weekly: 30)],
            enabledServices: [.xai]
        ))

        XCTAssertEqual(snapshots.map(\.service), [.xai])
    }

    func testProvidersWithoutMetricsAreIncludedForThePopoverAndFilterableForTheDashboard() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.xai: makeMetrics(service: .xai, weekly: 30)]
        ))

        // Popover shows every enabled provider, including empty-state cards.
        XCTAssertEqual(snapshots.count, 9)
        XCTAssertFalse(snapshots[0].hasMetrics)
        // …the dashboard filters to providers with data.
        XCTAssertEqual(snapshots.filter(\.hasMetrics).map(\.service), [.xai])
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
            enabledServices: [.codexCli, .claudeCode, .xai]
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
                GrokAccount.defaultID: makeMetrics(service: .xai, weekly: 14),
                work.id: makeMetrics(service: .xai, weekly: 79)
            ],
            enabledServices: [.xai]
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
        switch kind {
        case .session:
            switch service {
            case .openRouter: return .keyLimit
            case .claudeCode,
                 .codexCli,
                 .xai,
                 .kimiCode,
                 .zaiCodingPlan,
                 .githubCopilot,
                 .museCode,
                 .claudePlatform: return .session
            }
        case .weekly:
            switch service {
            case .openRouter, .claudePlatform: return .accountCredits
            case .claudeCode,
                 .codexCli,
                 .xai,
                 .kimiCode,
                 .zaiCodingPlan,
                 .githubCopilot,
                 .museCode: return .weekly
            }
        case .codeReview:
            switch service {
            case .claudeCode: return .model(label: modelLimitLabel)
            case .xai: return .onDemand
            case .codexCli,
                 .openRouter,
                 .kimiCode,
                 .zaiCodingPlan,
                 .githubCopilot,
                 .museCode,
                 .claudePlatform: return .codeReview
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
            for total in [ServiceType.xaiPercentPoolTotal, 500] {
                let metrics = UsageMetrics(
                    service: service,
                    sessionLimit: UsageLimit(used: 4, total: total, resetTime: nil),
                    weeklyLimit: UsageLimit(used: 64, total: total, resetTime: nil),
                    codeReviewLimit: UsageLimit(used: 12, total: total, resetTime: nil),
                    modelLimitLabel: service == .claudeCode ? "Fable" : nil
                )
                let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: service, scope: .providerWide))
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
            account: ProviderAccount(service: .claudeCode, scope: .providerWide)
        )
        XCTAssertEqual(labeled.map(\.quotaTitleKey), [.model(label: "Fable")])
        XCTAssertEqual(labeled.map(\.localizedTitle), ["Fable"])

        let unlabeled = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10),
            account: ProviderAccount(service: .claudeCode, scope: .providerWide)
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
            account: ProviderAccount(service: .claudeCode, scope: .providerWide)
        )
        let codexLimits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .codexCli, codeReview: 10),
            account: ProviderAccount(service: .codexCli, scope: .providerWide)
        )

        XCTAssertEqual(claudeLimits.map(\.title), ["Fable"])
        XCTAssertEqual(codexLimits.map(\.title), ["Code Review"])
    }

    func testLegacyClaudeModelLimitUsesNeutralLabel() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, codeReview: 10),
            account: ProviderAccount(service: .claudeCode, scope: .providerWide)
        )

        XCTAssertEqual(limits.map(\.title), ["Model"])
    }

    func testOpenRouterUsesCurrencyCreditLabels() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .openRouter, session: 10, weekly: 20),
            account: ProviderAccount(service: .openRouter, scope: .providerWide)
        )

        XCTAssertEqual(limits.map(\.title), ["Key limit", "Account credits"])
        XCTAssertTrue(limits.allSatisfy { $0.valueStyle == .currency })
    }

    // A legacy Cursor account's long window resets with `billingCycleEnd`. Its
    // percent-of-100 pools match the dashboard's Cursor Models / Other Models
    // bars and sit beside a monthly headline gauge; a request-count grant keeps
    // the Monthly label.
    private func legacyPool(_ used: Double, label: String) -> UsageLimit {
        UsageLimit(used: used, total: 100, resetTime: nil, label: label)
    }

    private func legacyPoolMetrics(autoUsed: Double, apiUsed: Double) -> UsageMetrics {
        let roomiest = min(autoUsed, apiUsed)
        return UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: roomiest, total: 100, resetTime: nil, periodKind: .monthly),
            additionalLimits: [
                legacyPool(autoUsed, label: ServiceType.legacyCursorModelsLabel),
                legacyPool(apiUsed, label: ServiceType.legacyOtherModelsLabel)
            ]
        )
    }

    func testCursorPercentPoolsUseDashboardTitles() {
        let limits = ProviderSnapshotBuilder.limits(
            for: legacyPoolMetrics(autoUsed: 4, apiUsed: 64),
            account: ProviderAccount(service: .xai, scope: .providerWide)
        )

        XCTAssertEqual(limits.map(\.title), ["Monthly", "Cursor Models", "Other Models"])
        XCTAssertEqual(limits.map(\.kind), [.weekly, .additional, .additional])
    }

    func testCursorLegacyRequestQuotaKeepsMonthlyLabel() {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 137, total: 500, resetTime: nil, periodKind: .monthly)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertEqual(limits.map(\.title), ["Monthly"])
    }

    func testCursorOnDemandWindowIsTitledOnDemand() {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil, periodKind: .monthly),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil),
            additionalLimits: [
                legacyPool(4, label: ServiceType.legacyCursorModelsLabel),
                legacyPool(64, label: ServiceType.legacyOtherModelsLabel)
            ]
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertEqual(limits.map(\.title), ["Monthly", "On-demand", "Cursor Models", "Other Models"])
    }

    // Cursor spends the included pool before it touches credits, so the weekly
    // gauge says so, but only while there are credits for that to matter.
    func testCursorWeeklyRowExplainsIncludedUsageComesBeforeCredits() {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertEqual(limits.first { $0.id == "weekly" }?.footnote, .includedBeforeCredits)
        XCTAssertEqual(
            limits.first { $0.id == "weekly" }?.localizedFootnote,
            "Included usage is spent before credits."
        )
        XCTAssertNil(limits.first { $0.id == "codeReview" }?.footnote)
    }

    func testCursorWeeklyRowHasNoNoteWithoutCredits() {
        let metrics = UsageMetrics(
            service: .xai,
            sessionLimit: UsageLimit(used: 4, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertTrue(limits.allSatisfy { $0.footnote == nil })
    }

    func testCursorSessionRowNeverCarriesTheCreditsNote() {
        let metrics = UsageMetrics(
            service: .xai,
            sessionLimit: UsageLimit(used: 4, total: 100, resetTime: nil),
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertNil(limits.first { $0.id == "session" }?.footnote)
        XCTAssertEqual(limits.first { $0.id == "weekly" }?.footnote, .includedBeforeCredits)
    }

    func testOtherProvidersNeverGetThexAICreditsNote() {
        let metrics = UsageMetrics(
            service: .claudeCode,
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .claudeCode, scope: .providerWide))

        XCTAssertTrue(limits.allSatisfy { $0.footnote == nil })
    }

    // Cursor sometimes omits the pool reset; the row must not invent one.
    func testCursorWeeklyRowWithoutResetShowsNoReset() {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 64, total: 100, resetTime: nil),
            codeReviewLimit: UsageLimit(used: 12, total: 40, resetTime: nil)
        )
        let weekly = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))
            .first { $0.id == "weekly" }

        XCTAssertNotNil(weekly)
        XCTAssertFalse(weekly.map { LimitRow.RowContent(limit: $0).showsReset } ?? true)
    }

    func testCursorSinglePoolExhaustionDoesNotCollapseTheCard() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "xAI",
            service: .xai,
            metrics: legacyPoolMetrics(autoUsed: 4, apiUsed: 100),
            emptyDetail: ""
        )

        // Spillover: the header follows the pool that still has room, not the
        // one that ran dry — the account is only "Out" when both are gone.
        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
        XCTAssertFalse(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertTrue(snapshot.blockingLimits.isEmpty)
        XCTAssertEqual(snapshot.detailLimits.map(\.kind), [.weekly, .additional, .additional])
    }

    func testCursorOtherModelsExhaustedStillReadsCursorModelsHeadroom() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "xAI",
            service: .xai,
            metrics: legacyPoolMetrics(autoUsed: 27, apiUsed: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.primaryLimit?.percentLeft, 73)
        XCTAssertEqual(snapshot.band, .healthy)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
    }

    func testCursorSpilloverBandTracksTheRoomiestPool() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "xAI",
            service: .xai,
            metrics: legacyPoolMetrics(autoUsed: 100, apiUsed: 92),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.band, .critical)
        XCTAssertFalse(snapshot.hasExhaustedLimit)
    }

    func testCursorLegacySinglePoolStillUsesTightestWindow() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .xai,
            metrics: makeMetrics(service: .xai, weekly: 100),
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
            service: .xai,
            sessionLimit: UsageLimit(used: 5, total: 50, resetTime: nil),
            weeklyLimit: UsageLimit(used: 500, total: 500, resetTime: nil),
            codeReviewLimit: nil
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .xai,
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
            title: "xAI",
            service: .xai,
            metrics: legacyPoolMetrics(autoUsed: 100, apiUsed: 100),
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.band, .exhausted)
        XCTAssertTrue(snapshot.hasExhaustedLimit)
        XCTAssertTrue(snapshot.hasExhaustedWeeklyLimit)
        XCTAssertEqual(snapshot.blockingLimits.map(\.kind), [.weekly])
    }

    func testPaceContextComesFromKindNotTitle() {
        let limits = ProviderSnapshotBuilder.limits(
            for: makeMetrics(service: .claudeCode, session: 10, weekly: 20, codeReview: 30),
            account: ProviderAccount(service: .claudeCode, scope: .providerWide)
        )

        XCTAssertEqual(limits.map(\.kind), [.session, .weekly, .codeReview])
        XCTAssertEqual(limits.map(\.paceContext), [.session, .weekly, .session])
    }

    /// Cursor's included pools now carry `periodKind: .monthly` (for the
    /// cadence-title headline) but `paceContext` still switches on `kind`, so
    /// pace copy for the session/weekly slots must stay byte-identical.
    func testPaceContextIgnoresPeriodKindForSessionAndWeeklySlots() {
        let metrics = makeMetrics(service: .xai, session: 10, weekly: 20)
        let monthlyMetrics = UsageMetrics(
            service: .xai,
            sessionLimit: UsageLimit(
                used: 10,
                total: ServiceType.xaiPercentPoolTotal,
                resetTime: metrics.sessionLimit?.resetTime,
                periodKind: .monthly
            ),
            weeklyLimit: UsageLimit(
                used: 20,
                total: ServiceType.xaiPercentPoolTotal,
                resetTime: metrics.weeklyLimit?.resetTime,
                periodKind: .monthly
            )
        )

        let limits = ProviderSnapshotBuilder.limits(for: monthlyMetrics, account: ProviderAccount(service: .xai, scope: .providerWide))

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
                .xai: makeMetrics(service: .xai, weekly: 97)
            ],
            enabledServices: [.codexCli, .xai]
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
                .xai: makeMetrics(service: .xai, weekly: 80)
            ],
            enabledServices: [.claudeCode, .xai]
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
            service: .xai,
            weeklyLimit: UsageLimit(
                used: 500,
                total: 500,
                resetTime: nil,
                isEstimated: true
            )
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "Cursor",
            service: .xai,
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
            service: .xai,
            weeklyLimit: UsageLimit(used: 41, total: 100, resetTime: nil, periodKind: .monthly)
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))
        let weekly = try? XCTUnwrap(limits.first { $0.id == "weekly" })

        XCTAssertEqual(weekly?.quotaTitleKey, .monthly)
        XCTAssertEqual(weekly?.title, "Monthly")
        XCTAssertEqual(weekly?.localizedTitle, "Monthly")
        XCTAssertFalse(weekly?.title.contains("Weekly") == true)
    }

    func testAdditionalLimitsBecomeExtraSnapshotRows() {
        let metrics = UsageMetrics(
            service: .xai,
            sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, periodKind: .session),
            weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil, periodKind: .weekly),
            additionalLimits: [
                UsageLimit(used: 30, total: 100, resetTime: nil, periodKind: .daily),
                UsageLimit(used: 40, total: 100, resetTime: nil, periodKind: .billing),
                UsageLimit(used: 50, total: 100, resetTime: nil, periodKind: .unknown)
            ]
        )
        let limits = ProviderSnapshotBuilder.limits(for: metrics, account: ProviderAccount(service: .xai, scope: .providerWide))

        XCTAssertEqual(limits.map(\.id), ["session", "weekly", "additional-0", "additional-1", "additional-2"])
        XCTAssertEqual(limits.map(\.quotaTitleKey), [.session, .weekly, .daily, .billingCycle, .quota])
        XCTAssertEqual(limits.map(\.title), ["Session", "Weekly", "Daily", "Billing cycle", "Quota"])
        XCTAssertEqual(limits.last?.localizedTitle, "Quota")
    }

    // MARK: - Merged xAI card

    /// A legacy Cursor account's monthly pools stay inside the one xAI card as
    /// extra rows; there is no separate sub-pool card.
    func testXAIWithLegacyCursorPoolsProducesOneSnapshot() {
        let metrics = UsageMetrics(
            service: .xai,
            weeklyLimit: UsageLimit(used: 20, total: ServiceType.xaiPercentPoolTotal, resetTime: nil, periodKind: .monthly),
            additionalLimits: [
                UsageLimit(used: 30, total: ServiceType.xaiPercentPoolTotal, resetTime: nil, label: ServiceType.legacyCursorModelsLabel),
                UsageLimit(used: 40, total: ServiceType.xaiPercentPoolTotal, resetTime: nil, label: ServiceType.legacyOtherModelsLabel)
            ]
        )
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.xai: metrics],
            enabledServices: [.xai]
        ))

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.title, "xAI")
        XCTAssertEqual(snapshots.first?.service, .xai)
        XCTAssertEqual(snapshots.first?.logoKind, .xai)
        XCTAssertEqual(snapshots.first?.limits.map(\.quotaTitleKey), [.monthly, .cursorModels, .otherModels])
    }

    func testXAISnapshotStaysSingularWithoutLegacyPools() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.xai: makeMetrics(service: .xai, session: 10, weekly: 20)],
            enabledServices: [.xai]
        ))

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.title, "xAI")
    }

    func testCreditRemainderBecomesThePrimaryMeterAndHidesTheInventedPercent() throws {
        let metrics = UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
            extraUsage: ExtraUsageStatus(state: .on, detail: "$61,586.14 in credits"),
            additionalLimits: [
                UsageLimit(
                    used: 0,
                    total: 61_586.14,
                    resetTime: nil,
                    label: "Credits",
                    reading: .remainder
                )
            ]
        )
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "shipshitdev",
            service: .codexCli,
            metrics: metrics,
            emptyDetail: ""
        )

        XCTAssertEqual(snapshot.primaryLimit?.id, "credits")
        XCTAssertEqual(snapshot.primaryLimit?.usageLimit.reading, .remainder)
        XCTAssertEqual(snapshot.limits.map(\.title), ["Credits"])
        XCTAssertEqual(
            ProviderCardPresentation.statusText(for: snapshot),
            "61,586.14 left"
        )
        XCTAssertNotEqual(snapshot.band, .exhausted)

        let creditLimit = try XCTUnwrap(snapshot.limits.first { $0.id == "credits" })
        XCTAssertEqual(creditLimit.valueStyle, .quota)
        let row = LimitRow.RowContent(limit: creditLimit)
        XCTAssertFalse(row.showsUsageBar)
        XCTAssertEqual(row.trailingText, "61,586.14 left")
        XCTAssertEqual(creditLimit.accessibilityValue, "61,586.14 left")
    }

    func testCreditAllowanceUsesARemainingBarAndWeeklyQuotaStaysPrimary() throws {
        let allowance = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
                additionalLimits: [
                    UsageLimit(used: 60, total: 100, resetTime: nil, label: "Credits", reading: .allowance)
                ]
            ),
            emptyDetail: ""
        )
        XCTAssertEqual(allowance.limits.map(\.title), ["Credits"])
        XCTAssertEqual(allowance.primaryLimit?.usageLimit.reading, .allowance)
        XCTAssertEqual(allowance.primaryLimit?.percentLeft, 40)
        XCTAssertEqual(ProviderCardPresentation.statusText(for: allowance), "40 left")
        let allowanceLimit = try XCTUnwrap(
            allowance.limits.first { $0.usageLimit.reading == .allowance }
        )
        let allowanceRow = LimitRow.RowContent(limit: allowanceLimit)
        XCTAssertTrue(allowanceRow.showsUsageBar)
        XCTAssertEqual(allowanceRow.trailingText, "40 left")

        let spentAllowance = LimitRow.RowContent(limit: SnapshotLimit(
            id: "credits",
            kind: .additional,
            quotaTitleKey: .model(label: "Credits"),
            usageLimit: UsageLimit(used: 100, total: 100, resetTime: nil, label: "Credits", reading: .allowance)
        ))
        XCTAssertTrue(spentAllowance.showsUsageBar)
        XCTAssertEqual(spentAllowance.trailingText, "0 left")

        let stillOnSubscription = ProviderSnapshotBuilder.snapshot(
            title: "Codex",
            service: .codexCli,
            metrics: UsageMetrics(
                service: .codexCli,
                weeklyLimit: UsageLimit(used: 36, total: 100, resetTime: nil)
            ),
            emptyDetail: ""
        )
        XCTAssertEqual(stillOnSubscription.primaryLimit?.title, "Weekly")
        XCTAssertEqual(stillOnSubscription.primaryLimit?.percentLeft, 64)
    }

    /// The dashboard Costs panel's per-provider selection: the merged xAI card
    /// is the only xAI snapshot, exhausted or not.
    func testAccountSnapshotSelectionReturnsTheXAICard() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.xai: makeMetrics(service: .xai, session: 100)],
            enabledServices: [.xai]
        ))
        XCTAssertTrue(snapshots.first?.hasExhaustedLimit == true, "fixture should be exhausted")

        XCTAssertEqual(snapshots.accountSnapshot(for: .xai)?.title, "xAI")
    }

    func testAccountCardCountIsOneForXAI() {
        let snapshots = ProviderSnapshotBuilder.snapshots(makeInput(
            metrics: [.xai: makeMetrics(service: .xai, session: 10, weekly: 20)],
            enabledServices: [.xai]
        ))

        XCTAssertEqual(snapshots.accountCardCount(for: .xai), 1)
    }
}
