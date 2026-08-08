import MeterBarShared
import SwiftUI

// Overview page extracted from UsageDashboardView.swift (C1 split). Pure move —
// the page takes its data as explicit inputs instead of reaching into the shell's
// private stores, and `OverviewSummaryStrip` travels with its only caller.

struct DashboardOverviewSection: View {
    let snapshots: [ProviderSnapshot]
    let tightestLimit: SnapshotLimit?
    let costSummary: CostSummary?
    let onSelectProvider: (ProviderSnapshot.ID) -> Void

    private static let masonryColumnCount = 2

    /// Copy for the "Use next" tile — the Optimize ranking's top pick, boiled
    /// down to one glance. Replaces the old "Tracked sources" tile, which was a
    /// Settings fact that almost always read "all reporting".
    ///
    /// Internal (not private) so the three states can be asserted without
    /// hosting the page, matching `OptimizeInsightsView.recentWindowTile`.
    static func useNextTile(
        for recommendation: ProviderRecommendation
    ) -> (value: String, caption: String, band: QuotaBand?) {
        if let top = recommendation.rows.first, !recommendation.isFullyExhausted {
            // `headroomText` already reads "44% left", so the window name leads.
            var parts = ["\(top.windowTitle) · \(top.headroomText)"]
            if let resetText = top.resetText {
                parts.append(resetText)
            }
            return (top.name, parts.joined(separator: " · "), top.band)
        }
        if recommendation.isFullyExhausted {
            let caption = recommendation.rows.first?.availabilityText ?? "Waiting for the next reset"
            return ("Every window spent", caption, .exhausted)
        }
        return ("No data", "Waiting for provider refresh", nil)
    }

    /// Deals items round-robin across `columnCount` independent columns.
    ///
    /// `LazyVGrid` locks every card in a row to the tallest card in that row, so
    /// a provider with two quota windows left a block of dead space beside a
    /// provider with four. Columns that flow on their own pack tight instead.
    /// Round-robin keeps reading order running left-to-right across each row
    /// and keeps the columns balanced to within one card.
    ///
    /// Internal (not private) so the ordering and balance can be unit-tested
    /// without hosting the page.
    nonisolated static func masonryColumns<Element>(_ items: [Element], columnCount: Int) -> [[Element]] {
        let count = max(1, columnCount)
        var columns = [[Element]](repeating: [], count: count)
        for (index, item) in items.enumerated() {
            columns[index % count].append(item)
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverviewSummaryStrip(
                snapshots: snapshots,
                tightestLimit: tightestLimit,
                estimatedCost: costSummary?.formattedTotalCost,
                formattedTokens: UsageFormat.tokens(costSummary?.totalTokens ?? 0)
            )

            HStack(alignment: .top, spacing: MeterBarTheme.Spacing.sm) {
                let columns = Self.masonryColumns(snapshots, columnCount: Self.masonryColumnCount)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                        ForEach(column) { snapshot in
                            // Same shared provider card as the popover and the
                            // Limits page; tapping it jumps to that provider in
                            // Limits.
                            ProviderStatusCard(
                                snapshot: snapshot,
                                onSelect: { onSelectProvider(snapshot.id) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OverviewSummaryStrip: View {
    let snapshots: [ProviderSnapshot]
    let tightestLimit: SnapshotLimit?
    let estimatedCost: String?
    let formattedTokens: String

    // Same gutter as the provider masonry below it, so the page reads as one
    // grid rather than two with different spacing.
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 180), spacing: MeterBarTheme.Spacing.sm),
        count: 3
    )

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            TimelineView(
                .periodic(
                    from: ResetCountdownSchedule.anchor,
                    by: ResetCountdownSchedule.interval
                )
            ) { timeline in
                DashboardMetricTile(
                    title: "Tightest window",
                    value: tightestValue(now: timeline.date),
                    caption: tightestCaption,
                    systemImage: tightestIconName,
                    indicatorTint: tightestColor,
                    style: .compact
                )
            }

            DashboardMetricTile(
                title: "30-day estimate",
                value: estimatedCost ?? "Scan needed",
                caption: "\(formattedTokens) tokens",
                systemImage: "chart.bar.xaxis",
                style: .compact
            )

            // The Optimize ranking's top pick, on the same countdown clock as
            // the tightest-window tile so its reset caption stays current.
            TimelineView(
                .periodic(
                    from: ResetCountdownSchedule.anchor,
                    by: ResetCountdownSchedule.interval
                )
            ) { timeline in
                let tile = DashboardOverviewSection.useNextTile(
                    for: snapshots.headroomRecommendation(now: timeline.date)
                )
                DashboardMetricTile(
                    title: "Use next",
                    value: tile.value,
                    caption: tile.caption,
                    systemImage: "arrow.forward.circle",
                    indicatorTint: tile.band?.color ?? .secondary,
                    style: .compact
                )
            }
        }
    }

    private var tightestBand: QuotaBand? {
        tightestLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    private var tightestColor: Color {
        tightestBand?.color ?? .secondary
    }

    private var tightestIconName: String {
        tightestBand?.iconName ?? "circle.dashed"
    }

    private var tightestCaption: String {
        guard let tightestLimit else { return "Waiting for provider refresh" }
        return "\(tightestLimit.title) quota"
    }

    private func tightestValue(now: Date) -> String {
        guard let tightestLimit else { return "No data" }
        guard tightestLimit.usageLimit.isAtLimit else {
            return tightestLimit.usageLimit.percentLeftText
        }
        if tightestLimit.usageLimit.isEstimated {
            return tightestLimit.usageLimit.percentLeftText
        }
        guard let countdown = tightestLimit.usageLimit.resetCountdownText(now: now) else {
            return "Reset unknown"
        }
        return countdown == "now" ? "Reset due" : "Resets in \(countdown)"
    }
}
