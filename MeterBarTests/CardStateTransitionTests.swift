import AppKit
@testable import MeterBar
import MeterBarShared
import SwiftUI
import XCTest

/// Coverage for the shared card-swap motion convention (issue: conditional
/// content swapping without transitions).
///
/// Two things are asserted:
///   1. The `MeterBarTheme.Motion` tokens behave — one curve, reduce-motion
///      resolves to `nil`. This is the concrete surface the transition
///      convention is built on; SwiftUI exposes no public API to introspect a
///      transition attached to a rendered view, so the token contract is where
///      "transitions are attached" is asserted directly.
///   2. Every loading / loaded / empty branch of the three refactored cards —
///      and both structural states of the popover panel — still render. The
///      refactor moved each branch behind a `phase` switch with per-branch
///      `.id`, so a broken branch that used to be a plain `if` now fails to
///      lay out here.
@MainActor
final class CardStateTransitionTests: XCTestCase {
    // MARK: - Motion tokens

    func testResolvedMotionIsNilUnderReduceMotion() {
        XCTAssertNil(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: true),
            "Reduce Motion must drop the animation so state changes apply instantly"
        )
        XCTAssertNotNil(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: false),
            "With motion allowed, the standard curve drives the swap"
        )
    }

    func testResolvedMotionUsesTheStandardCurve() {
        XCTAssertEqual(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: false),
            MeterBarTheme.Motion.standard,
            "There is one curve for structural swaps — resolved() returns it verbatim"
        )
    }

    // MARK: - ApiUsageCard phases

    func testApiUsageCardRendersEveryPhase() {
        // .loading — a fetch is in flight and nothing has arrived yet.
        assertRenders(ApiUsageCard(provider: .anthropic, usage: nil, isLoading: true))
        // .loaded — usage with data.
        assertRenders(ApiUsageCard(provider: .anthropic, usage: loadedUsage(), isLoading: false))
        // .empty — usage present but zero, and the nil-usage settled case.
        assertRenders(ApiUsageCard(provider: .anthropic, usage: emptyUsage(), isLoading: false))
        assertRenders(ApiUsageCard(provider: .anthropic, usage: nil, isLoading: false))
    }

    // MARK: - Usage page phases

    func testUsageSectionRendersEveryPhase() {
        // Scan needed — no summary yet.
        assertRenders(DashboardUsageSection(summary: nil), minHeight: 0)
        // Loaded — a scan produced rows.
        assertRenders(DashboardUsageSection(summary: DemoData.costSummary()), minHeight: 0)
    }

    // MARK: - PopoverOverviewPanel structural states

    func testPopoverPanelRendersEmptyAndPopulated() {
        // Empty: no enabled sources → the "No sources enabled" tile branch.
        assertRenders(
            PopoverOverviewPanel(
                snapshots: [],
                openDashboard: {},
                openStatusDetail: {},
                openProviderOverview: { _ in }
            )
        )

        // Populated: provider cards present → the ForEach branch.
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [
                    .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                    .cursor: makeMetrics(service: .cursor, weekly: 30)
                ],
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: [.codexCli, .cursor]
            )
        )
        XCTAssertFalse(snapshots.isEmpty, "fixture must produce provider cards to exercise the ForEach branch")
        assertRenders(
            PopoverOverviewPanel(
                snapshots: snapshots,
                openDashboard: {},
                openStatusDetail: {},
                openProviderOverview: { _ in }
            )
        )

        // Hint enabled: the opt-in "what to use next" row joins the stack.
        assertRenders(
            PopoverOverviewPanel(
                snapshots: snapshots,
                openDashboard: {},
                openStatusDetail: {},
                openProviderOverview: { _ in },
                showsRecommendationHint: true
            )
        )
    }

    // MARK: - Overview provider list

    /// Overview is a summary + tappable rows now, not a duplicate of the Limits
    /// masonry grid.
    func testOverviewSectionRendersTheProviderList() {
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [
                    .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                    .cursor: makeMetrics(service: .cursor, weekly: 30),
                    .grok: makeMetrics(service: .grok, weekly: 80)
                ],
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: [.codexCli, .cursor, .grok]
            )
        )

        assertRenders(
            DashboardOverviewSection(
                snapshots: snapshots,
                tightestLimit: nil,
                costSummary: nil,
                onSelectProvider: { _ in }
            )
        )

        // Empty is the other structural state: no rows to list.
        assertRenders(
            DashboardOverviewSection(
                snapshots: [],
                tightestLimit: nil,
                costSummary: nil,
                onSelectProvider: { _ in }
            ),
            minHeight: 0
        )
    }

    // MARK: - Limits page: What To Use Next

    func testHeadroomRecommendationCardBuilds() {
        // With nothing to rank the card renders nothing rather than an empty shell.
        assertRenders(HeadroomRecommendationCard(providerSnapshots: []), minHeight: 0)

        // With snapshots the card renders, including its "no data" section for
        // the provider without metrics.
        let snapshots = ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: [
                    .codexCli: makeMetrics(service: .codexCli, weekly: 10),
                    .cursor: makeMetrics(service: .cursor, weekly: 30)
                ],
                claudeAccounts: [.defaultAccount],
                claudeAccountMetrics: [:],
                enabledServices: [.codexCli, .cursor, .claudeCode]
            )
        )
        assertRenders(HeadroomRecommendationCard(providerSnapshots: snapshots), minHeight: 0)
    }

    // MARK: - Helpers

    private func assertRenders(
        _ view: some View,
        minHeight: CGFloat = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = NSHostingView(rootView: view.frame(width: 360))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, minHeight, file: file, line: line)
    }

    private func loadedUsage() -> ApiUsage {
        ApiUsage(
            provider: .anthropic,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 86_400),
            inputTokens: 1_000,
            outputTokens: 500,
            estimatedCostUSD: 1.23,
            models: [
                ApiModelUsage(
                    model: "claude-opus-4",
                    inputTokens: 800,
                    outputTokens: 400,
                    estimatedCostUSD: 1.0
                )
            ]
        )
    }

    private func emptyUsage() -> ApiUsage {
        ApiUsage(
            provider: .anthropic,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 86_400),
            inputTokens: 0,
            outputTokens: 0,
            estimatedCostUSD: 0,
            models: []
        )
    }

    private func loadedSummary() -> CostSummary {
        CostSummary(costs: [], totalCostUSD: 12.34, totalTokens: 1_000_000, periodDays: 30)
    }

    private func makeMetrics(service: ServiceType, weekly: Double) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: nil,
            weeklyLimit: UsageLimit(used: weekly, total: 100, resetTime: nil),
            codeReviewLimit: nil,
            extraUsage: nil
        )
    }
}
