import MeterBarShared
import XCTest

final class WidgetBurnDownTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let windowSeconds: TimeInterval = 5 * 60 * 60

    func testBurnDownLocalizedCopyUsesStructuredFieldsNotPlannerEnglish() {
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownTitle(.projectedExhaustion, locale: Locale(identifier: "en")),
            "Projected empty in"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownTitle(.reset, locale: Locale(identifier: "en")),
            "Resets in"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownCountdownTitle(.unavailable, locale: Locale(identifier: "en")),
            "Countdown"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownStageText(
                stage: .unavailable,
                health: .stale,
                fallback: "ignored",
                locale: Locale(identifier: "en")
            ),
            "Stale data"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownStageText(
                stage: .unavailable,
                health: .unavailable,
                fallback: "ignored",
                locale: Locale(identifier: "en")
            ),
            "Usage unavailable"
        )
        XCTAssertEqual(
            LocalizedUsageFormat.burnDownStageText(
                stage: .unavailable,
                health: .healthy,
                fallback: "ignored",
                locale: Locale(identifier: "en")
            ),
            "Pace unavailable"
        )
    }

    func testBurnDownUsesADistinctStableWidgetKind() {
        XCTAssertEqual(MeterBarWidgetKind.usage, "UsageWidget")
        XCTAssertEqual(MeterBarWidgetKind.burnDown, "BurnDownWidget")
        XCTAssertNotEqual(MeterBarWidgetKind.usage, MeterBarWidgetKind.burnDown)
    }

    func testReservePaceCountsDownToReset() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let row = try XCTUnwrap(
            presentation(metrics: [.claudeCode: metrics(.claudeCode, used: 40, resetTime: resetTime)])
                .rows.first
        )

        XCTAssertEqual(row.stage, .reserve)
        XCTAssertEqual(row.stageText, "10% in reserve")
        XCTAssertEqual(row.countdownKind, .reset)
        XCTAssertEqual(row.countdownTitle, "Resets in")
        XCTAssertEqual(row.countdownTarget, resetTime)
        XCTAssertEqual(row.countdownText, "2h 30m")
    }

    func testDeficitPaceCountsDownToProjectedExhaustion() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let row = try XCTUnwrap(
            presentation(metrics: [.claudeCode: metrics(.claudeCode, used: 75, resetTime: resetTime)])
                .rows.first
        )

        XCTAssertEqual(row.stage, .deficit)
        XCTAssertEqual(row.stageText, "25% in deficit")
        XCTAssertEqual(row.countdownKind, .projectedExhaustion)
        XCTAssertEqual(row.countdownTitle, "Projected empty in")
        XCTAssertEqual(try XCTUnwrap(row.countdownTarget).timeIntervalSince(now), 50 * 60, accuracy: 0.01)
        XCTAssertEqual(row.countdownText, "50m")
    }

    func testExhaustedWindowCountsDownToReset() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let row = try XCTUnwrap(
            presentation(metrics: [.codexCli: metrics(.codexCli, used: 100, resetTime: resetTime)])
                .rows.first
        )

        XCTAssertEqual(row.stage, .deficit)
        XCTAssertEqual(row.stageText, "Out of quota")
        XCTAssertTrue(row.isExhausted)
        XCTAssertEqual(row.countdownKind, .reset)
        XCTAssertEqual(row.countdownTarget, resetTime)
        XCTAssertEqual(row.countdownText, "2h 30m")
    }

    func testStaleDataKeepsResetCountdownButSuppressesProjection() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let staleMetrics = metrics(
            .claudeCode,
            used: 75,
            resetTime: resetTime,
            lastUpdated: now.addingTimeInterval(-3 * 60 * 60)
        )
        let row = try XCTUnwrap(presentation(metrics: [.claudeCode: staleMetrics]).rows.first)

        XCTAssertEqual(row.health, .stale)
        XCTAssertEqual(row.stage, .unavailable)
        XCTAssertEqual(row.stageText, "Stale data")
        XCTAssertEqual(row.countdownKind, .reset)
        XCTAssertEqual(row.countdownTarget, resetTime)
        XCTAssertTrue(row.accessibilityValueText.contains("Stale usage data"))
    }

    func testEstimatedOrIncompleteLimitNeverClaimsAPaceProjection() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let estimated = metrics(
            .claudeCode,
            used: 75,
            resetTime: resetTime,
            isEstimated: true
        )
        let incomplete = UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(used: 75, total: 100, resetTime: resetTime),
            lastUpdated: now
        )

        for metric in [estimated, incomplete] {
            let row = try XCTUnwrap(presentation(metrics: [metric.service: metric]).rows.first)
            XCTAssertEqual(row.stage, .unavailable)
            XCTAssertEqual(row.stageText, "Pace unavailable")
            XCTAssertEqual(row.countdownKind, .reset)
            XCTAssertEqual(row.countdownTarget, resetTime)
        }
    }

    func testMissingExplicitSelectionRendersUnavailableRatherThanDisappearing() throws {
        let missing = WidgetAccountIdentifier.account(service: .codexCli, id: UUID())
        var preferences = WidgetPreferences.defaults
        preferences.accountSelection = .explicit([missing])

        let row = try XCTUnwrap(presentation(metrics: [:], preferences: preferences).rows.first)

        XCTAssertEqual(row.accountIdentifier, missing)
        XCTAssertEqual(row.health, .unavailable)
        XCTAssertEqual(row.stage, .unavailable)
        XCTAssertEqual(row.countdownKind, .unavailable)
        XCTAssertEqual(row.countdownText, "Unavailable")
        XCTAssertTrue(row.accessibilityValueText.contains("Usage unavailable"))
    }

    func testNoSelectionAndEmptyCacheRemainDistinctEmptyStates() {
        var noSelectionPreferences = WidgetPreferences.defaults
        noSelectionPreferences.accountSelection = .explicit([])

        let noSelection = presentation(metrics: [:], preferences: noSelectionPreferences)
        let unavailable = presentation(metrics: [:])

        XCTAssertEqual(noSelection.emptyState, .noSelection)
        XCTAssertEqual(unavailable.emptyState, .unavailable)
    }

    func testAccountSelectionWindowSelectionAndOrderingComeFromWidgetPreferences() throws {
        let selectedID = UUID()
        let unselectedID = UUID()
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        var preferences = WidgetPreferences.defaults
        preferences.accountSelection = .explicit([
            .account(service: .claudeCode, id: selectedID)
        ])
        preferences.visibleQuotaWindows = [.session]
        let accounts = [
            AccountUsageSnapshot(
                id: unselectedID,
                name: "Personal",
                metrics: metrics(.claudeCode, used: 40, resetTime: resetTime)
            ),
            AccountUsageSnapshot(
                id: selectedID,
                name: "Work",
                metrics: metrics(
                    .claudeCode,
                    used: 75,
                    resetTime: resetTime,
                    window: .session
                )
            )
        ]

        let row = try XCTUnwrap(
            presentation(metrics: [:], accountMetrics: accounts, preferences: preferences).rows.first
        )

        XCTAssertEqual(row.accountName, "Work")
        XCTAssertEqual(row.accountIdentifier, .account(service: .claudeCode, id: selectedID))
        XCTAssertEqual(row.quotaWindow, .session)
    }

    func testSmallAndMediumUsePurposeBuiltRowBudgetsWithAccurateOverflow() {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let metricsByService: [ServiceType: UsageMetrics] = [
            .claudeCode: metrics(.claudeCode, used: 10, resetTime: resetTime),
            .codexCli: metrics(.codexCli, used: 20, resetTime: resetTime),
            .cursor: metrics(.cursor, used: 30, resetTime: resetTime)
        ]

        let small = presentation(metrics: metricsByService, family: .small)
        let medium = presentation(metrics: metricsByService, family: .medium)

        XCTAssertEqual(small.rows.count, 1)
        XCTAssertEqual(small.hiddenRowCount, 2)
        XCTAssertEqual(medium.rows.count, 2)
        XCTAssertEqual(medium.hiddenRowCount, 1)
    }

    func testTimelineRefreshesAtNearestMeaningfulBoundaryWithinFifteenMinutes() throws {
        let resetTime = now.addingTimeInterval(2.5 * 60 * 60)
        let nearExhaustion = try XCTUnwrap(
            presentation(metrics: [.claudeCode: metrics(.claudeCode, used: 98, resetTime: resetTime)])
                .rows.first?.countdownTarget
        )
        let presentation = presentation(
            metrics: [.claudeCode: metrics(.claudeCode, used: 98, resetTime: resetTime)]
        )

        XCTAssertEqual(
            WidgetBurnDownTimeline.nextUpdateDate(after: now, presentation: presentation),
            nearExhaustion
        )

        let longReset = presentationForReset(in: 60 * 60)
        XCTAssertEqual(
            WidgetBurnDownTimeline.nextUpdateDate(after: now, presentation: longReset),
            now.addingTimeInterval(15 * 60)
        )
    }

    func testTimelineDoesNotRequestReloadsMoreOftenThanOncePerMinute() {
        let resetTime = now.addingTimeInterval(10)
        let presentation = presentation(
            metrics: [.claudeCode: metrics(.claudeCode, used: 100, resetTime: resetTime)]
        )

        XCTAssertEqual(
            WidgetBurnDownTimeline.nextUpdateDate(after: now, presentation: presentation),
            now.addingTimeInterval(60)
        )
    }

    private func presentationForReset(in interval: TimeInterval) -> WidgetBurnDownPresentation {
        presentation(
            metrics: [
                .claudeCode: metrics(
                    .claudeCode,
                    used: 10,
                    resetTime: now.addingTimeInterval(interval),
                    windowSeconds: max(windowSeconds, interval * 2)
                )
            ]
        )
    }

    private func presentation(
        metrics: [ServiceType: UsageMetrics],
        accountMetrics: [AccountUsageSnapshot] = [],
        preferences: WidgetPreferences = .defaults,
        family: WidgetPresentationFamily = .medium
    ) -> WidgetBurnDownPresentation {
        WidgetBurnDownPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: accountMetrics,
            preferences: preferences,
            family: family,
            now: now
        )
    }

    private func metrics(
        _ service: ServiceType,
        used: Double,
        resetTime: Date,
        lastUpdated: Date? = nil,
        isEstimated: Bool = false,
        window: WidgetQuotaWindow = .weekly,
        windowSeconds: TimeInterval? = nil
    ) -> UsageMetrics {
        let limit = UsageLimit(
            used: used,
            total: 100,
            resetTime: resetTime,
            windowSeconds: windowSeconds ?? self.windowSeconds,
            isEstimated: isEstimated
        )
        return UsageMetrics(
            service: service,
            sessionLimit: window == .session ? limit : nil,
            weeklyLimit: window == .weekly ? limit : nil,
            codeReviewLimit: window == .codeReview ? limit : nil,
            lastUpdated: lastUpdated ?? now
        )
    }
}
