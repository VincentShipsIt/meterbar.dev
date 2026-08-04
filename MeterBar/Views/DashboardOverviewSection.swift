import MeterBarShared
import SwiftUI

// Overview page extracted from UsageDashboardView.swift (C1 split). Pure move —
// the page takes its data as explicit inputs instead of reaching into the shell's
// private stores, and `OverviewSummaryStrip` travels with its only caller.

struct DashboardOverviewSection: View {
    let snapshots: [ProviderSnapshot]
    let tightestLimit: SnapshotLimit?
    let enabledSourceCount: Int
    let costSummary: CostSummary?
    let onSelectProvider: (ProviderSnapshot.ID) -> Void

    private static let masonryColumnCount = 2

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
                tightestLimit: tightestLimit,
                sourceCount: snapshots.count,
                enabledSourceCount: enabledSourceCount,
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
    let tightestLimit: SnapshotLimit?
    let sourceCount: Int
    let enabledSourceCount: Int
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

            DashboardMetricTile(
                title: "Tracked sources",
                value: "\(sourceCount)",
                caption: sourceCaption,
                systemImage: "checklist.checked",
                style: .compact
            )
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

    private var sourceCaption: String {
        if enabledSourceCount == 0 {
            return "Enable providers in Settings"
        }
        if sourceCount == enabledSourceCount {
            return "All enabled sources reporting"
        }
        return "\(sourceCount) of \(enabledSourceCount) enabled reporting"
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
