import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Hosting smoke tests for the Token Activity card, plus the regression that
/// adding it left the 30-day chart and Daily Details surfaces untouched.
@MainActor
final class TokenActivityCardTests: XCTestCase {
    // MARK: - Hosting

    func testLoadedCardHostsWithAFullYearOfCells() {
        let card = TokenActivityCard(
            summary: makeSummary(dayCount: 90),
            isScanning: false,
            isScanDisabled: false,
            scan: {}
        )

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testEmptyCardHostsAndOffersTheLocalScan() {
        var scans = 0
        let card = TokenActivityCard(
            summary: nil,
            isScanning: false,
            isScanDisabled: false,
            scan: { scans += 1 }
        )

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        XCTAssertEqual(scans, 0, "the scan only runs when the button is pressed")
    }

    func testScanningCardHosts() {
        let card = TokenActivityCard(
            summary: nil,
            isScanning: true,
            isScanDisabled: true,
            scan: {}
        )

        let hostingView = NSHostingView(rootView: card)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testHeatmapHostsOnItsOwn() {
        let activity = TokenActivityCalendar(summary: makeSummary(dayCount: 400))
        let heatmap = TokenActivityHeatmap(activity: activity)

        let hostingView = NSHostingView(rootView: heatmap)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 240)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        XCTAssertEqual(activity.weeks.count, TokenActivityCalendar.defaultWeeks)
    }

    // MARK: - Placement regression

    func testCostsSectionStillHostsWithTheNewCard() {
        let section = DashboardCostsSection(summary: makeSummary(dayCount: 30)) { _ in nil }

        let hostingView = NSHostingView(rootView: section)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testThirtyDayChartAndDailyDetailsAreUnchanged() {
        let summary = makeSummary(dayCount: 30)

        // The heatmap reads the same `dailyUsage` contract but must not narrow
        // or reshape what the existing surfaces receive.
        XCTAssertEqual(
            DashboardCostsSection.refreshStatusText(isScanning: true, isRefreshingMissingDays: true),
            "Scanning..."
        )
        XCTAssertEqual(CostChartPresentation(summary: summary).hasSpend, true)

        let details = DashboardCard(title: "Daily Details", trailing: "Last 30 days") {
            DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
        }
        let hostingView = NSHostingView(rootView: details)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    // MARK: - Fixtures

    private func makeSummary(dayCount: Int) -> CostSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dailyUsage: [DailyTokenUsage] = (0..<dayCount).flatMap { offset -> [DailyTokenUsage] in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            // Every third day is a confirmed zero so the fixture exercises the
            // empty band as well as the graduated ones.
            guard !offset.isMultiple(of: 3) else { return [] }
            return [
                DailyTokenUsage(
                    date: date,
                    provider: .claudeCode,
                    inputTokens: 10_000 * (offset + 1),
                    outputTokens: 2_000,
                    cacheReadTokens: 500,
                    estimatedCostUSD: Double(offset + 1) * 0.75
                ),
                DailyTokenUsage(
                    date: date,
                    provider: .codexCli,
                    inputTokens: 4_000,
                    outputTokens: 900,
                    cacheReadTokens: 0,
                    estimatedCostUSD: 0.25
                ),
            ]
        }
        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: 1_000_000,
            outputTokens: 200_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 50_000,
            estimatedCostUSD: 42.5,
            sessionCount: 12,
            periodStart: calendar.date(byAdding: .day, value: -dayCount, to: today) ?? today,
            periodEnd: today
        )
        return CostSummary(
            costs: [cost],
            totalCostUSD: cost.estimatedCostUSD,
            totalTokens: cost.totalTokens,
            periodDays: 30,
            dailyUsage: dailyUsage
        )
    }
}
