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

    private func makeMetrics(
        _ service: ServiceType,
        sessionUsed: Double? = nil,
        weeklyUsed: Double? = nil,
        codeReviewUsed: Double? = nil,
        modelLimitLabel: String? = nil,
        resetTime: Date? = nil,
        lastUpdated: Date? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: sessionUsed.map {
                UsageLimit(used: $0, total: 100, resetTime: resetTime)
            },
            weeklyLimit: weeklyUsed.map {
                UsageLimit(used: $0, total: 100, resetTime: resetTime)
            },
            codeReviewLimit: codeReviewUsed.map {
                UsageLimit(used: $0, total: 100, resetTime: resetTime)
            },
            modelLimitLabel: modelLimitLabel,
            lastUpdated: lastUpdated ?? now
        )
    }
}
