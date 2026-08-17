import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Locks the invariants the demo / sample-data fixture must uphold so the
/// landing-page screenshots and the first-run onboarding preview stay
/// on-message: populated, mostly-green, exactly one amber band, no red, no
/// owner project names, and a non-alarming cost estimate.
final class DemoDataTests: XCTestCase {
    /// Fixed clock so reset timers — and therefore the pace math below — are
    /// deterministic across runs and rendered screenshots.
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Coverage & generic labels

    func testCoversEveryServiceTypeKeyedByGenericLabels() {
        let metrics = DemoData.metrics(now: now)

        XCTAssertEqual(Set(metrics.keys), Set(ServiceType.allCases))
        // Labels come from the service enum's product display names, never the
        // owner's custom account/profile names.
        for service in ServiceType.allCases {
            XCTAssertEqual(metrics[service]?.service.displayName, service.displayName)
        }
        // The one free-text label the fixture sets is a model window name, not a
        // project name.
        XCTAssertEqual(metrics[.claudeCode]?.modelLimitLabel, "Fable")
    }

    func testEveryProviderHasData() {
        let metrics = DemoData.metrics(now: now)
        for service in ServiceType.allCases {
            XCTAssertEqual(metrics[service]?.hasData, true, "\(service) should have data")
        }
    }

    // MARK: - Quota bands: mostly green, exactly one tight, zero red

    func testQuotaBandsAreMostlyHealthyWithExactlyOneTightAndNoRed() {
        let metrics = DemoData.metrics(now: now)
        let bands = allWindows(in: metrics).map(QuotaBand.forLimit)

        XCTAssertEqual(bands.filter { $0 == .tight }.count, 1, "exactly one amber 'tight' band")
        XCTAssertEqual(bands.filter { $0 == .critical }.count, 0, "no critical red bands")
        XCTAssertEqual(bands.filter { $0 == .exhausted }.count, 0, "no exhausted red bands")
        XCTAssertEqual(
            bands.filter { $0 == .healthy }.count,
            bands.count - 1,
            "every window except the single tight band is healthy"
        )
    }

    func testCodexWeeklyIsTheSingleTightBand() {
        let metrics = DemoData.metrics(now: now)
        let codexWeekly = try? XCTUnwrap(metrics[.codexCli]?.weeklyLimit)
        XCTAssertEqual(codexWeekly.map(QuotaBand.forLimit), .tight)
    }

    // MARK: - Trajectory: healthy, never a deficit

    func testNoWindowReadsAsADeficitOnTrajectory() {
        let metrics = DemoData.metrics(now: now)
        for limit in allWindows(in: metrics) {
            if let stage = limit.pace(now: now)?.stage {
                XCTAssertNotEqual(stage, .deficit, "no window should read as 'Out'/deficit")
            }
        }
    }

    func testTightCodexWeeklyStillReadsAsReserveNotDeficit() {
        let metrics = DemoData.metrics(now: now)
        let codexWeekly = metrics[.codexCli]?.weeklyLimit
        XCTAssertEqual(codexWeekly?.pace(now: now)?.stage, .reserve)
    }

    // MARK: - Freshness

    func testDataIsFreshSoEverySurfaceTreatsItAsHealthy() {
        let metrics = DemoData.metrics(now: now)
        for service in metrics.keys {
            XCTAssertEqual(metrics[service]?.lastUpdated, now, "\(service) should be stamped 'now'")
        }
    }

    // MARK: - Provider specifics

    func testCodexExposesBankedResetCreditsAndCursorHasNoPacedWindow() {
        let metrics = DemoData.metrics(now: now)

        XCTAssertEqual(metrics[.codexCli]?.resetCreditsAvailable, 2)
        XCTAssertEqual(metrics[.grok]?.resetCreditsAvailable, 1)
        XCTAssertNotNil(metrics[.claudeCode]?.extraUsage)
        XCTAssertNotNil(metrics[.grok]?.extraUsage)
        XCTAssertNil(metrics[.grok]?.sessionLimit)
        // Cursor included pools have no window seconds, so no pace label.
        // Grok Bot is a separate weekly additional bar with a ~7-day window.
        XCTAssertNil(metrics[.cursor]?.sessionLimit?.pace(now: now))
        XCTAssertNil(metrics[.cursor]?.weeklyLimit?.pace(now: now))
        XCTAssertEqual(metrics[.cursor]?.additionalLimits.count, 1)
        XCTAssertEqual(metrics[.cursor]?.additionalLimits.first?.periodKind, .weekly)
        XCTAssertEqual(metrics[.cursor]?.additionalLimits.first?.total, ServiceType.cursorIncludedPoolTotal)
        XCTAssertEqual(
            ServiceType.cursor.additionalQuotaTitleKey(
                for: metrics[.cursor]?.additionalLimits.first
                    ?? UsageLimit(used: 0, total: 0, resetTime: nil)
            ),
            .grokBot
        )
    }

    // MARK: - Cost summary: non-alarming, synthetic breakdowns only

    func testCostSummaryIsNonAlarmingAndCarriesOnlySyntheticBreakdowns() {
        let summary = DemoData.costSummary(now: now)

        XCTAssertEqual(summary.totalCostUSD, 240.10, accuracy: 0.001, "~$240, deliberately modest")
        XCTAssertEqual(summary.periodDays, 30)
        XCTAssertNil(summary.lifetime)
        XCTAssertEqual(summary.costs.count, ServiceType.allCases.count)
        XCTAssertEqual(Set(summary.costs.map(\.provider)), Set(ServiceType.allCases))
        XCTAssertEqual(
            summary.totalTokens,
            summary.costs.reduce(0) { $0 + $1.totalTokens },
            "summary total is the sum of its per-provider costs"
        )
        XCTAssertGreaterThan(summary.totalTokens, 0)

        // Breakdowns exist so demo screenshots show the model/origin charts —
        // but only from the fixture's fixed synthetic vocabulary. Nothing here
        // may ever look like a real project path or leak private routing.
        for cost in summary.costs where cost.provider.writesLocalTokenLogs {
            XCTAssertFalse(cost.modelBreakdowns.isEmpty, "\(cost.provider) demo needs model rows")
            XCTAssertFalse(cost.originBreakdowns.isEmpty, "\(cost.provider) demo needs origin rows")

            let attributed = cost.modelBreakdowns.reduce(0) { $0 + $1.estimatedCostUSD }
            XCTAssertEqual(
                attributed,
                cost.estimatedCostUSD,
                accuracy: 0.005,
                "\(cost.provider) model rows must reconcile — no Unattributed remainder in demo"
            )

            for breakdown in cost.modelBreakdowns + cost.originBreakdowns {
                XCTAssertTrue(
                    DemoData.syntheticBreakdownNames.contains(breakdown.name),
                    "unexpected demo breakdown name: \(breakdown.name)"
                )
                XCTAssertFalse(breakdown.name.contains("/"), "no path-like names in demo data")
            }
        }

        // Dollar-billed providers have no token telemetry; they stay plain.
        for provider in ServiceType.allCases where !provider.writesLocalTokenLogs {
            let cost = summary.costs.first { $0.provider == provider }
            XCTAssertEqual(cost?.modelBreakdowns.isEmpty, true, "\(provider)")
        }
    }

    /// Daily rows carry per-model attribution so the 7-day window's model chart
    /// derives from them instead of falling back to the mismatch caption.
    func testDemoDailyRowsCarryReconcilingModelAttribution() {
        let summary = DemoData.costSummary(now: now)

        for row in summary.dailyUsage {
            let models = row.modelBreakdowns ?? []
            XCTAssertFalse(models.isEmpty, "daily rows need model attribution for windowed charts")
            XCTAssertEqual(
                models.reduce(0) { $0 + $1.estimatedCostUSD },
                row.estimatedCostUSD,
                accuracy: 0.005,
                "daily model rows must reconcile to the day's cost"
            )
            for model in models {
                XCTAssertTrue(DemoData.syntheticBreakdownNames.contains(model.name))
            }
        }
    }

    func testDailyUsageIsPopulatedAndExcludesTheDollarBilledProvider() {
        let summary = DemoData.costSummary(now: now)

        XCTAssertFalse(summary.dailyUsage.isEmpty)
        // Dollar-billed providers contribute cost only and never appear as a
        // token row. Local-log providers fill the daily chart.
        let tokenProviders = Set(ServiceType.allCases.filter(\.writesLocalTokenLogs))
        XCTAssertFalse(summary.dailyUsage.contains { !$0.provider.writesLocalTokenLogs })
        XCTAssertEqual(Set(summary.dailyUsage.map(\.provider)), tokenProviders)
        // One row per token-billed provider per day across the 30-day window.
        XCTAssertEqual(summary.dailyUsage.count, 30 * tokenProviders.count)
    }

    func testFixtureIsDeterministicForAGivenClock() {
        let a = DemoData.metrics(now: now)
        let b = DemoData.metrics(now: now)
        XCTAssertEqual(a[.codexCli]?.weeklyLimit?.used, b[.codexCli]?.weeklyLimit?.used)
        XCTAssertEqual(
            DemoData.costSummary(now: now).totalCostUSD,
            DemoData.costSummary(now: now).totalCostUSD
        )
    }

    // MARK: - Helpers

    private func allWindows(in metrics: [ServiceType: UsageMetrics]) -> [UsageLimit] {
        metrics.values.flatMap { metric in
            [metric.sessionLimit, metric.weeklyLimit, metric.codeReviewLimit].compactMap { $0 }
                + metric.additionalLimits
        }
    }
}
