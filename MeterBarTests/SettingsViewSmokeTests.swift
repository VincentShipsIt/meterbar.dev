import AppKit
@testable import MeterBar
import SwiftUI
import XCTest

@MainActor
final class SettingsViewSmokeTests: XCTestCase {
    func testStandaloneSettingsBuildsACompactTabbedLayout() {
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
        hostingView.layoutSubtreeIfNeeded()

        // Compact, MacSweep-style: a fixed 760x660 tabbed window, not a wide sidebar.
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 720)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, 820)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 560)
    }

    func testProviderNotConnectedEmptyStateRendersInSettingsSection() {
        // Mirrors the real composition: the unified EmptyStateCard nested inside
        // a SettingsPanelSection tile, at the settings column width. Guards that
        // the migrated not-connected notices lay out where the old stacked
        // SettingsNotices used to.
        let section = SettingsPanelSection(
            title: "Cursor",
            systemImage: "person.crop.circle",
            color: MeterBarTheme.cursorAccent
        ) {
            EmptyStateCard(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Not connected",
                message: "Log in to Cursor IDE, then Check Again.",
                tone: .warning
            )
        }

        let hostingView = NSHostingView(rootView: section.frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    /// Cost Tracking's "Scan 30 Days" (`.glassProminent`) and the Refresh
    /// section's "Refresh Now" (`.glass`) are the Settings CTAs that adopted
    /// Liquid Glass button styles. SwiftPM CI can't drive AppKit hit-testing, so
    /// this smoke test guards the next best thing: that those glass-styled
    /// buttons still compile and lay out inside the real Settings tree. A removed
    /// button or an invalid `.glass`/`.glassProminent` style regresses here — the
    /// action wiring itself is covered by the cost-scan and refresh unit tests.
    func testGlassCostScanAndRefreshCTAsStillRender() {
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.width, 720)
    }

    func testAboutSettingsExposeProjectLinks() {
        XCTAssertEqual(AboutSettingsView.links.map(\.id), ["website", "github", "x"])
        XCTAssertEqual(
            AboutSettingsView.links.map(\.detail),
            ["meterbar.dev", "VincentShipsIt/meterbar.dev", "@shipshitdev"]
        )
        XCTAssertEqual(
            AboutSettingsView.links.map { $0.url.absoluteString },
            [
                "https://meterbar.dev",
                "https://github.com/VincentShipsIt/meterbar.dev",
                "https://x.com/shipshitdev",
            ]
        )

        let hostingView = NSHostingView(rootView: AboutSettingsView().frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    // MARK: - Cost views (issue #270: month-to-date, display currency, projects)

    private var referenceMonthStart: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 1))!
    }

    /// A synthetic summary independent of `CostTracker.shared`'s live scan
    /// state: one provider with cached daily rows spanning this month and
    /// last month (so `monthToDateCostWindow` has something to filter), plus
    /// a project rollup that includes an explicit "unknown" bucket and a
    /// nested model breakdown — the shape `CostPeriodContentView` renders.
    private func makeSyntheticCostSummary() -> CostSummary {
        let calendar = Calendar(identifier: .gregorian)
        let thisMonthDay = calendar.date(byAdding: .day, value: 2, to: referenceMonthStart)!
        let lastMonthDay = calendar.date(byAdding: .day, value: -3, to: referenceMonthStart)!

        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: 1_000,
            outputTokens: 250,
            cacheCreationTokens: 50,
            cacheReadTokens: 500,
            estimatedCostUSD: 12.5,
            sessionCount: 4,
            periodStart: lastMonthDay,
            periodEnd: thisMonthDay,
            projectBreakdowns: [
                TokenUsageBreakdown(
                    provider: .claudeCode,
                    name: "www/example/app",
                    inputTokens: 900,
                    outputTokens: 200,
                    cacheCreationTokens: 40,
                    cacheReadTokens: 400,
                    estimatedCostUSD: 10,
                    sessionCount: 3,
                    modelBreakdowns: [
                        TokenUsageBreakdown(
                            provider: .claudeCode,
                            name: "claude-opus-5",
                            inputTokens: 900,
                            outputTokens: 200,
                            cacheCreationTokens: 40,
                            cacheReadTokens: 400,
                            estimatedCostUSD: 10,
                            sessionCount: 3
                        ),
                    ]
                ),
                TokenUsageBreakdown(
                    provider: .claudeCode,
                    name: "unknown",
                    inputTokens: 100,
                    outputTokens: 50,
                    cacheCreationTokens: 10,
                    cacheReadTokens: 100,
                    estimatedCostUSD: 2.5,
                    sessionCount: 1
                ),
            ]
        )

        return CostSummary(
            costs: [cost],
            totalCostUSD: 12.5,
            totalTokens: cost.totalTokens,
            periodDays: 30,
            dailyUsage: [
                DailyTokenUsage(
                    date: thisMonthDay,
                    provider: .claudeCode,
                    inputTokens: 500,
                    outputTokens: 125,
                    cacheReadTokens: 250,
                    estimatedCostUSD: 6
                ),
                DailyTokenUsage(
                    date: lastMonthDay,
                    provider: .claudeCode,
                    inputTokens: 500,
                    outputTokens: 125,
                    cacheReadTokens: 250,
                    estimatedCostUSD: 6.5
                ),
            ]
        )
    }

    func testCostPeriodContentRendersLast30DaysWithProjectBreakdownDrillDown() {
        let view = CostPeriodContentView(summary: makeSyntheticCostSummary(), periodMode: .last30Days, currency: nil)
        let hostingView = NSHostingView(rootView: view.frame(width: 640))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testCostPeriodContentRendersMonthToDateWindowFromCachedDailyUsage() {
        let view = CostPeriodContentView(summary: makeSyntheticCostSummary(), periodMode: .monthToDate, currency: nil)
        let hostingView = NSHostingView(rootView: view.frame(width: 640))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testCostPeriodContentRendersConvertedCurrencyCaptionWhenSupplied() {
        let currency = DisplayCurrency(code: "EUR", unitsPerUSD: 0.92, enteredAt: referenceMonthStart)
        let view = CostPeriodContentView(
            summary: makeSyntheticCostSummary(),
            periodMode: .last30Days,
            currency: currency
        )
        let hostingView = NSHostingView(rootView: view.frame(width: 640))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }

    func testCostSettingsViewRendersDisplayCurrencySectionAlongsideCostTracking() {
        // Hosts the real tab (real singletons, like testGlassCostScanAndRefreshCTAsStillRender
        // above) so a broken Display Currency section or period picker fails to compile/layout
        // here even though CostTracker.shared may hold no scan in the test process.
        let hostingView = NSHostingView(rootView: CostSettingsView().frame(width: 720))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
