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

    func testCoversThreeProvidersKeyedByGenericServiceType() {
        let metrics = DemoData.metrics(now: now)

        XCTAssertEqual(Set(metrics.keys), [.claudeCode, .codexCli, .cursor])
        // Labels come from the service enum's product display names, never the
        // owner's custom account/profile names.
        XCTAssertEqual(metrics[.claudeCode]?.service.displayName, "Claude Code")
        XCTAssertEqual(metrics[.codexCli]?.service.displayName, "OpenAI Codex")
        XCTAssertEqual(metrics[.cursor]?.service.displayName, "Cursor")
        // The one free-text label the fixture sets is a model window name, not a
        // project name.
        XCTAssertEqual(metrics[.claudeCode]?.modelLimitLabel, "Fable")
    }

    func testEveryProviderHasData() {
        let metrics = DemoData.metrics(now: now)
        for service in [ServiceType.claudeCode, .codexCli, .cursor] {
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
        // Cursor mirrors the real dollar-denominated mapping: no window seconds,
        // so no pace label is ever produced.
        XCTAssertNil(metrics[.cursor]?.sessionLimit?.pace(now: now))
        XCTAssertNil(metrics[.cursor]?.weeklyLimit?.pace(now: now))
    }

    // MARK: - Cost summary: non-alarming, no project/model leakage

    func testCostSummaryIsNonAlarmingAndLeaksNoOriginOrModelBreakdowns() {
        let summary = DemoData.costSummary(now: now)

        XCTAssertEqual(summary.totalCostUSD, 204.90, accuracy: 0.001, "~$205, deliberately modest")
        XCTAssertEqual(summary.periodDays, 30)
        XCTAssertNil(summary.lifetime)
        XCTAssertEqual(summary.costs.count, 3)
        XCTAssertEqual(Set(summary.costs.map(\.provider)), [.claudeCode, .codexCli, .cursor])
        XCTAssertEqual(
            summary.totalTokens,
            summary.costs.reduce(0) { $0 + $1.totalTokens },
            "summary total is the sum of its per-provider costs"
        )
        XCTAssertGreaterThan(summary.totalTokens, 0)

        // Never surface real project paths or private model routing.
        for cost in summary.costs {
            XCTAssertTrue(cost.modelBreakdowns.isEmpty, "\(cost.provider) must carry no model breakdown")
            XCTAssertTrue(cost.originBreakdowns.isEmpty, "\(cost.provider) must carry no origin breakdown")
        }
    }

    func testDailyUsageIsPopulatedAndExcludesTheDollarBilledProvider() {
        let summary = DemoData.costSummary(now: now)

        XCTAssertFalse(summary.dailyUsage.isEmpty)
        // Cursor is billed in dollars (0 tokens) so it contributes cost only and
        // never appears as a token row.
        XCTAssertFalse(summary.dailyUsage.contains { $0.provider == .cursor })
        XCTAssertTrue(summary.dailyUsage.allSatisfy { [.claudeCode, .codexCli].contains($0.provider) })
        // One row per token-billed provider per day across the 30-day window.
        XCTAssertEqual(summary.dailyUsage.count, 30 * 2)
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
        }
    }
}
