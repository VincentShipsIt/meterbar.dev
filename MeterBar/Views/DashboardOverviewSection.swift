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

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
            count: 2
        )
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

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                ForEach(snapshots) { snapshot in
                    // Same shared provider card as the popover and the Limits
                    // page; tapping it jumps to that provider in Limits.
                    ProviderStatusCard(
                        snapshot: snapshot,
                        onSelect: { onSelectProvider(snapshot.id) }
                    )
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

    private let columns = [
        GridItem(.flexible(minimum: 180), spacing: 12),
        GridItem(.flexible(minimum: 180), spacing: 12),
        GridItem(.flexible(minimum: 180), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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
