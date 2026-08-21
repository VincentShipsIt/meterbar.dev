import Foundation
import MeterBarShared
import XCTest

final class WidgetPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFamilyBudgetsReserveOverflowSlotAndReportExactOmittedCount() {
        let cases: [(WidgetPresentationFamily, Int, Int, Int)] = [
            (.small, 3, 3, 0),
            (.small, 4, 2, 2),
            (.medium, 3, 3, 0),
            (.medium, 4, 2, 2),
            (.large, 7, 7, 0),
            (.large, 8, 6, 2)
        ]

        for (family, total, visible, hidden) in cases {
            let budget = WidgetFamilyRowBudget.plan(totalRowCount: total, family: family)
            XCTAssertEqual(budget.visibleRowCount, visible, "\(family) visible rows")
            XCTAssertEqual(budget.hiddenRowCount, hidden, "\(family) hidden rows")
        }

        XCTAssertEqual(
            WidgetFamilyRowBudget.plan(totalRowCount: -1, family: .small),
            WidgetFamilyRowBudget(visibleRowCount: 0, hiddenRowCount: 0)
        )
    }

    func testDetailedFamilyBudgetsLeaveRoomForMetadataAndOverflow() {
        XCTAssertEqual(
            WidgetFamilyRowBudget.plan(
                totalRowCount: 3,
                family: .medium,
                showsDetails: true
            ),
            WidgetFamilyRowBudget(visibleRowCount: 2, hiddenRowCount: 1)
        )
        XCTAssertEqual(
            WidgetFamilyRowBudget.plan(
                totalRowCount: 6,
                family: .large,
                showsDetails: true
            ),
            WidgetFamilyRowBudget(visibleRowCount: 5, hiddenRowCount: 1)
        )
    }

    func testEnabledResetDetailsDoNotReduceBudgetWhenNoRowHasResetMetadata() {
        var preferences = WidgetPreferences.defaults
        preferences.showsResetTime = true
        let result = presentation(
            metrics: [
                .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 10),
                .codexCli: makeMetrics(.codexCli, weeklyUsed: 20),
                .cursor: makeMetrics(.cursor, weeklyUsed: 30)
            ],
            preferences: preferences,
            family: .medium
        )

        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.hiddenRowCount, 0)
        XCTAssertTrue(result.rows.allSatisfy { $0.resetTime == nil })
    }

    func testEveryFamilyAppliesTheSameProviderOrderingBeforeItsBudget() {
        let metrics: [ServiceType: UsageMetrics] = [
            .openRouter: makeMetrics(.openRouter, weeklyUsed: 40),
            .cursor: makeMetrics(.cursor, weeklyUsed: 30),
            .codexCli: makeMetrics(.codexCli, weeklyUsed: 20),
            .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 10)
        ]
        let expectedOrder: [ServiceType] = [.claudeCode, .codexCli, .cursor, .openRouter]

        let small = presentation(metrics: metrics, family: .small)
        let medium = presentation(metrics: metrics, family: .medium)
        let large = presentation(metrics: metrics, family: .large)

        XCTAssertEqual(small.rows.map(\.service), Array(expectedOrder.prefix(2)))
        XCTAssertEqual(small.hiddenRowCount, 2)
        XCTAssertEqual(medium.rows.map(\.service), Array(expectedOrder.prefix(2)))
        XCTAssertEqual(medium.hiddenRowCount, 2)
        XCTAssertEqual(large.rows.map(\.service), expectedOrder)
        XCTAssertEqual(large.hiddenRowCount, 0)
    }

    func testUrgencyOrderingUsesOnlySelectedWindowsAndFallsBackToProviderOrder() {
        var preferences = WidgetPreferences.defaults
        preferences.accountOrdering = .urgency
        preferences.visibleQuotaWindows = [.weekly]
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, sessionUsed: 99, weeklyUsed: 10),
            .codexCli: makeMetrics(.codexCli, sessionUsed: 5, weeklyUsed: 80),
            .cursor: makeMetrics(.cursor, sessionUsed: 60, weeklyUsed: 80)
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(result.rows.map(\.service), [.codexCli, .cursor, .claudeCode])
    }

    func testUrgencyOrderingIncludesVisibleAdditionalLimits() {
        var preferences = WidgetPreferences.defaults
        preferences.accountOrdering = .urgency
        preferences.visibleQuotaWindows = [.weekly]
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 90),
            .cursor: makeMetrics(
                .cursor,
                weeklyUsed: 10,
                additionalLimits: [
                    UsageLimit(used: 100, total: 100, resetTime: nil, periodKind: .weekly)
                ]
            )
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(uniqueServices(in: result), [.cursor, .claudeCode])
    }

    func testUrgencyOrderingIgnoresAdditionalLimitsOutsideVisibleWindows() {
        var preferences = WidgetPreferences.defaults
        preferences.accountOrdering = .urgency
        preferences.visibleQuotaWindows = [.weekly]
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 90),
            .cursor: makeMetrics(
                .cursor,
                weeklyUsed: 10,
                additionalLimits: [
                    UsageLimit(used: 100, total: 100, resetTime: nil, periodKind: .daily)
                ]
            )
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(result.rows.map(\.service), [.claudeCode, .cursor])
    }

    func testUrgencyOrderingUsesWidgetWindowForAdditionalLimitPeriod() {
        var preferences = WidgetPreferences.defaults
        preferences.accountOrdering = .urgency
        preferences.visibleQuotaWindows = [.session]
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, sessionUsed: 20, weeklyUsed: 90),
            .cursor: makeMetrics(
                .cursor,
                sessionUsed: 5,
                weeklyUsed: 10,
                additionalLimits: [
                    UsageLimit(used: 100, total: 100, resetTime: nil, periodKind: .daily)
                ]
            )
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(uniqueServices(in: result), [.cursor, .claudeCode])
    }

    func testUsedAndRemainingModesProduceComplementaryValues() throws {
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 25)
        ]
        var usedPreferences = WidgetPreferences.defaults
        usedPreferences.displayMode = .used
        var remainingPreferences = usedPreferences
        remainingPreferences.displayMode = .remaining

        let used = try XCTUnwrap(
            presentation(metrics: metrics, preferences: usedPreferences).rows.first
        )
        let remaining = try XCTUnwrap(
            presentation(metrics: metrics, preferences: remainingPreferences).rows.first
        )

        XCTAssertEqual(used.progressValue, 25)
        XCTAssertEqual(used.summaryText, "25% used")
        XCTAssertEqual(remaining.progressValue, 75)
        XCTAssertEqual(remaining.summaryText, "75% left")
        XCTAssertEqual(used.progressTotal, remaining.progressTotal)
    }

    func testOpenRouterDefaultsToLegacyRemainingBalanceUntilDisplayModeIsChosen() throws {
        let metrics: [ServiceType: UsageMetrics] = [
            .openRouter: makeMetrics(.openRouter, weeklyUsed: 25)
        ]
        let legacy = try XCTUnwrap(presentation(metrics: metrics).rows.first)
        var explicitlyUsed = WidgetPreferences.defaults
        explicitlyUsed.preservesLegacyOpenRouterBalance = false

        let used = try XCTUnwrap(
            presentation(metrics: metrics, preferences: explicitlyUsed).rows.first
        )

        XCTAssertEqual(legacy.displayMode, .used)
        XCTAssertEqual(legacy.progressValue, 25)
        XCTAssertEqual(legacy.summaryText, "$75.00 left")
        XCTAssertEqual(legacy.compactSummaryText, "$75.00")
        XCTAssertEqual(used.displayMode, .used)
        XCTAssertEqual(used.summaryText, "$25.00 used")
        XCTAssertEqual(used.compactSummaryText, "$25.00 used")
    }

    func testSelectedQuotaWindowsUseStableOrderAndIgnoreUnavailableWindows() {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = [.codeReview, .weekly, .session]
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(
                .claudeCode,
                sessionUsed: 10,
                weeklyUsed: 20,
                codeReviewUsed: 30,
                modelLimitLabel: "Fable"
            ),
            .cursor: makeMetrics(.cursor, sessionUsed: nil, weeklyUsed: 40)
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(
            result.rows.map { "\($0.service.rawValue):\($0.quotaWindow.rawValue)" },
            [
                "Claude Code:session",
                "Claude Code:weekly",
                "Claude Code:codeReview",
                "Cursor:weekly"
            ]
        )
        XCTAssertEqual(result.rows[2].quotaTitle, "Fable")
        // The shared window id stays `weekly`; only Cursor's display copy
        // follows its billing-cycle reset. Percent-of-100 pools match the
        // dashboard's Other Models bar.
        XCTAssertEqual(result.rows[1].quotaTitle, "Weekly")
        XCTAssertEqual(result.rows[3].quotaTitle, "Other Models")
    }

    func testResetAndFreshnessMetadataObeyIndependentToggles() throws {
        let resetTime = now.addingTimeInterval(600)
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(
                .claudeCode,
                weeklyUsed: 25,
                resetTime: resetTime
            )
        ]

        for showsReset in [false, true] {
            for showsFreshness in [false, true] {
                var preferences = WidgetPreferences.defaults
                preferences.showsResetTime = showsReset
                preferences.showsFreshness = showsFreshness

                let row = try XCTUnwrap(
                    presentation(metrics: metrics, preferences: preferences).rows.first
                )

                XCTAssertEqual(row.resetTime, showsReset ? resetTime : nil)
                XCTAssertEqual(row.freshnessDate, showsFreshness ? now : nil)
            }
        }
    }

    func testStalenessBoundaryIsHealthyAndOneSecondOlderIsStale() throws {
        let threshold: TimeInterval = 3_600
        let atBoundary: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(
                .claudeCode,
                weeklyUsed: 25,
                lastUpdated: now.addingTimeInterval(-threshold)
            )
        ]
        let older: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(
                .claudeCode,
                weeklyUsed: 25,
                lastUpdated: now.addingTimeInterval(-threshold - 1)
            )
        ]

        let healthy = try XCTUnwrap(
            presentation(metrics: atBoundary, stalenessThreshold: threshold).rows.first
        )
        let stale = try XCTUnwrap(
            presentation(metrics: older, stalenessThreshold: threshold).rows.first
        )

        XCTAssertEqual(healthy.health, .healthy)
        XCTAssertNotNil(healthy.usageStatus)
        XCTAssertEqual(stale.health, .stale)
        XCTAssertNil(stale.usageStatus)
    }

    func testExplicitMissingSelectionIsUnavailableRatherThanHealthy() throws {
        var preferences = WidgetPreferences.defaults
        let missing = WidgetAccountIdentifier.account(
            service: .codexCli,
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9))
        )
        preferences.accountSelection = .explicit([missing])

        let row = try XCTUnwrap(
            presentation(metrics: [:], preferences: preferences).rows.first
        )

        XCTAssertEqual(row.accountIdentifier, missing)
        XCTAssertEqual(row.service, .codexCli)
        XCTAssertEqual(row.health, .unavailable)
        XCTAssertNil(row.usageStatus)
        XCTAssertEqual(row.summaryText, "Unavailable")
    }

    func testMissingAccountProducesOneUnavailableRowWithoutHidingHealthyRows() {
        var preferences = WidgetPreferences.defaults
        let missing = WidgetAccountIdentifier.account(
            service: .codexCli,
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9))
        )
        preferences.accountSelection = .explicit([.provider(.claudeCode), missing])
        preferences.visibleQuotaWindows = [.session, .weekly, .codeReview]

        let result = presentation(
            metrics: [
                .claudeCode: makeMetrics(
                    .claudeCode,
                    sessionUsed: 10,
                    weeklyUsed: 20,
                    codeReviewUsed: 30
                )
            ],
            preferences: preferences,
            family: .large
        )

        XCTAssertEqual(result.rows.count, 4)
        XCTAssertEqual(result.rows.filter { $0.health == .unavailable }.count, 1)
        XCTAssertEqual(result.hiddenRowCount, 0)
    }

    func testExplicitEmptySelectionAndUnavailableCacheHaveDistinctStates() {
        var noSelectionPreferences = WidgetPreferences.defaults
        noSelectionPreferences.accountSelection = .explicit([])

        let noSelection = presentation(
            metrics: [.cursor: makeMetrics(.cursor, weeklyUsed: 20)],
            preferences: noSelectionPreferences
        )
        let unavailable = presentation(metrics: [:])

        XCTAssertEqual(noSelection.emptyState, .noSelection)
        XCTAssertTrue(noSelection.emptyState?.detail.contains("MeterBar Settings") ?? false)
        XCTAssertEqual(unavailable.emptyState, .unavailable)
        XCTAssertNotEqual(noSelection.emptyState, unavailable.emptyState)
    }

    func testOverflowCountsOnlySelectedAvailableQuotaRows() {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = [.session, .weekly]
        preferences.accountSelection = .explicit([.provider(.claudeCode)])
        let metrics: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, sessionUsed: 10, weeklyUsed: 20),
            .codexCli: makeMetrics(.codexCli, sessionUsed: 30, weeklyUsed: 40),
            .cursor: makeMetrics(.cursor, sessionUsed: nil, weeklyUsed: 50)
        ]

        let result = presentation(
            metrics: metrics,
            preferences: preferences,
            family: .small
        )

        XCTAssertEqual(result.rows.map(\.quotaWindow), [.session, .weekly])
        XCTAssertEqual(result.hiddenRowCount, 0)
    }

    func testAccountSnapshotsReplaceAggregateProviderRowAndPreserveNames() {
        let firstID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let secondID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        let aggregate: [ServiceType: UsageMetrics] = [
            .claudeCode: makeMetrics(.claudeCode, weeklyUsed: 90)
        ]
        let accounts = [
            AccountUsageSnapshot(
                id: firstID,
                name: "Personal",
                metrics: makeMetrics(.claudeCode, weeklyUsed: 10)
            ),
            AccountUsageSnapshot(
                id: secondID,
                name: "Work",
                metrics: makeMetrics(.claudeCode, weeklyUsed: 20)
            )
        ]

        let result = presentation(
            metrics: aggregate,
            accountMetrics: accounts,
            family: .large
        )

        XCTAssertEqual(result.rows.map(\.accountName), ["Personal", "Work"])
        XCTAssertEqual(
            result.rows.map(\.accountIdentifier),
            [
                .account(service: .claudeCode, id: firstID),
                .account(service: .claudeCode, id: secondID)
            ]
        )
    }

    // MARK: - Demo mode

    func testMediumWidgetRendersDemoDataAsHealthyRowsWithSingleAmberBand() {
        let result = presentation(
            metrics: DemoData.metrics(now: now),
            family: .medium
        )

        XCTAssertNil(result.emptyState)
        XCTAssertFalse(result.rows.isEmpty)
        // Fresh (`lastUpdated == now`), so every row is healthy — never stale.
        XCTAssertTrue(result.rows.allSatisfy { $0.health == .healthy })
        // Mostly green with exactly one amber band, and zero red.
        let statuses = result.rows.map(\.usageStatus)
        XCTAssertEqual(statuses.filter { $0 == .warning }.count, 1)
        XCTAssertFalse(statuses.contains(.critical))
        // Only generic product providers, never owner project names.
        XCTAssertTrue(result.rows.allSatisfy { Set(ServiceType.allCases).contains($0.service) })
    }

    // MARK: - Quota title routing

    /// Which quota title a row shows is one decision with two readers: the app
    /// and CLI take `quotaTitle`, the widget extension localizes
    /// `quotaTitleKey`. The extension used to re-derive the routing from
    /// `(service, quotaWindow)` on its own side, so this pins the two to the
    /// same answer for every provider, window, and Cursor pool shape.
    func testQuotaTitleIsDerivedFromTheSharedRoutingKey() {
        for service in ServiceType.allCases {
            for total in [ServiceType.cursorIncludedPoolTotal, 500] {
                for row in allWindowRows(service: service, total: total) {
                    XCTAssertEqual(
                        row.quotaTitle,
                        row.quotaTitleKey.englishTitle,
                        "\(service) \(row.quotaWindow) total \(total)"
                    )
                    XCTAssertEqual(
                        row.quotaTitleKey,
                        expectedQuotaTitleKey(
                            service: service,
                            window: row.quotaWindow,
                            total: total
                        ),
                        "\(service) \(row.quotaWindow) total \(total)"
                    )
                }
            }
        }
    }

    /// The routing table itself, spelled out once so a change to it has to be
    /// deliberate. Cursor's included pools are the percent-of-100 shape;
    /// anything else is the legacy request quota.
    private func expectedQuotaTitleKey(
        service: ServiceType,
        window: WidgetQuotaWindow,
        total: Double
    ) -> ServiceType.QuotaTitleKey {
        let isIncludedPool = ServiceType.isCursorIncludedPool(total: total)
        switch (service, window) {
        case (.claudeCode, .codeReview): return .model(label: "Fable")
        case (.cursor, .codeReview): return .onDemand
        case (_, .codeReview): return .codeReview
        case (.openRouter, .session): return .keyLimit
        case (.cursor, .session): return isIncludedPool ? .cursorModels : .session
        case (_, .session): return .session
        case (.openRouter, .weekly): return .accountCredits
        case (.cursor, .weekly): return isIncludedPool ? .otherModels : .monthly
        case (_, .weekly): return .weekly
        }
    }

    private func uniqueServices(in presentation: WidgetPresentation) -> [ServiceType] {
        var seen = Set<WidgetAccountIdentifier>()
        return presentation.rows.compactMap { row in
            guard seen.insert(row.accountIdentifier).inserted else { return nil }
            return row.service
        }
    }

    /// One row per quota window for a single provider, built through the real
    /// planner rather than a hand-made row.
    private func allWindowRows(service: ServiceType, total: Double) -> [WidgetPresentationRow] {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = Set(WidgetQuotaWindow.allCases)
        let rows = presentation(
            metrics: [
                service: makeMetrics(
                    service,
                    sessionUsed: 10,
                    weeklyUsed: 10,
                    codeReviewUsed: 10,
                    total: total,
                    modelLimitLabel: "Fable"
                )
            ],
            preferences: preferences,
            family: .large
        ).rows
        XCTAssertEqual(
            Set(rows.map(\.quotaWindow)),
            Set(WidgetQuotaWindow.allCases),
            "\(service): every quota window must be represented"
        )
        return rows
    }

    private func presentation(
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [AccountUsageSnapshot] = [],
        preferences: WidgetPreferences = .defaults,
        family: WidgetPresentationFamily = .large,
        stalenessThreshold: TimeInterval = WidgetPresentationPlanner.defaultStalenessThreshold
    ) -> WidgetPresentation {
        WidgetPresentationPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: accountMetrics,
            preferences: preferences,
            family: family,
            now: now,
            stalenessThreshold: stalenessThreshold
        )
    }

    func testGrokMonthlyWeeklySlotIsTitledMonthlyNeverWeekly() {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = [.weekly]
        let presentation = presentation(
            metrics: [
                .grok: UsageMetrics(
                    service: .grok,
                    weeklyLimit: UsageLimit(used: 41, total: 100, resetTime: nil, periodKind: .monthly),
                    lastUpdated: now
                )
            ],
            preferences: preferences
        )
        let row = presentation.rows.first { $0.service == .grok && $0.quotaWindow == .weekly }

        XCTAssertEqual(row?.quotaTitleKey, .monthly)
        XCTAssertEqual(row?.quotaTitle, "Monthly")
        XCTAssertNotEqual(row?.quotaTitle, "Weekly")
    }

    func testAdditionalLimitsAppearAsExtraWidgetRows() {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = Set(WidgetQuotaWindow.allCases)
        let presentation = presentation(
            metrics: [
                .grok: UsageMetrics(
                    service: .grok,
                    sessionLimit: UsageLimit(used: 10, total: 100, resetTime: nil, periodKind: .session),
                    weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil, periodKind: .weekly),
                    additionalLimits: [
                        UsageLimit(used: 30, total: 100, resetTime: nil, periodKind: .daily)
                    ],
                    lastUpdated: now
                )
            ],
            preferences: preferences
        )
        let titles = presentation.rows.filter { $0.service == .grok }.map(\.quotaTitle)

        XCTAssertTrue(titles.contains("Session"))
        XCTAssertTrue(titles.contains("Weekly"))
        XCTAssertTrue(titles.contains("Daily"), titles.joined(separator: ", "))
    }

    func testCursorAdditionalWeeklyPercentPoolIsTitledGrokBotNotOtherModels() {
        var preferences = WidgetPreferences.defaults
        preferences.visibleQuotaWindows = Set(WidgetQuotaWindow.allCases)
        let presentation = presentation(
            metrics: [
                .cursor: UsageMetrics(
                    service: .cursor,
                    sessionLimit: UsageLimit(
                        used: 4,
                        total: ServiceType.cursorIncludedPoolTotal,
                        resetTime: nil
                    ),
                    weeklyLimit: UsageLimit(
                        used: 64,
                        total: ServiceType.cursorIncludedPoolTotal,
                        resetTime: nil
                    ),
                    additionalLimits: [
                        UsageLimit(
                            used: 18,
                            total: ServiceType.cursorIncludedPoolTotal,
                            resetTime: nil,
                            periodKind: .weekly
                        )
                    ],
                    lastUpdated: now
                )
            ],
            preferences: preferences
        )
        let titles = presentation.rows.filter { $0.service == .cursor }.map(\.quotaTitle)
        let keys = presentation.rows.filter { $0.service == .cursor }.map(\.quotaTitleKey)

        XCTAssertTrue(titles.contains("Cursor Models"), titles.joined(separator: ", "))
        XCTAssertTrue(titles.contains("Other Models"), titles.joined(separator: ", "))
        XCTAssertTrue(titles.contains("Grok Bot"), titles.joined(separator: ", "))
        XCTAssertTrue(keys.contains(.grokBot), "\(keys)")
        XCTAssertEqual(keys.filter { $0 == .otherModels }.count, 1)
    }

    private func makeMetrics(
        _ service: ServiceType,
        sessionUsed: Double? = nil,
        weeklyUsed: Double? = nil,
        codeReviewUsed: Double? = nil,
        total: Double = 100,
        modelLimitLabel: String? = nil,
        resetTime: Date? = nil,
        lastUpdated: Date? = nil,
        additionalLimits: [UsageLimit] = []
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: sessionUsed.map {
                UsageLimit(used: $0, total: total, resetTime: resetTime)
            },
            weeklyLimit: weeklyUsed.map {
                UsageLimit(used: $0, total: total, resetTime: resetTime)
            },
            codeReviewLimit: codeReviewUsed.map {
                UsageLimit(used: $0, total: total, resetTime: resetTime)
            },
            modelLimitLabel: modelLimitLabel,
            additionalLimits: additionalLimits,
            lastUpdated: lastUpdated ?? now
        )
    }
}
