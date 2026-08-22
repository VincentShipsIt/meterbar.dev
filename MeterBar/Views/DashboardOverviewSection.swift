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

    /// Providers that need a decision or are running low, sorted ahead of the
    /// healthy ones. Auth overlays beat quota bands.
    static func sortedForOverview(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.sorted { lhs, rhs in
            let left = attentionRank(for: lhs)
            let right = attentionRank(for: rhs)
            if left != right { return left > right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func needsAttention(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.authNotice != nil
            || (snapshot.band?.severityRank ?? 0) >= QuotaBand.tight.severityRank
    }

    /// One-line summary under each overview row — enough to decide whether to
    /// open Limits, without replaying every quota bar.
    static func detailLine(for snapshot: ProviderSnapshot, now: Date) -> String {
        if let authNotice = snapshot.authNotice {
            return authNotice.shortLabel
        }
        guard let limit = snapshot.primaryLimit else {
            return snapshot.emptyDetail
        }
        var parts = ["\(limit.localizedTitle) · \(LocalizedUsageFormat.percentLeft(limit.usageLimit))"]
        if needsAttention(snapshot),
           let countdown = limit.usageLimit.resetCountdownText(now: now),
           countdown != "now" {
            parts.append("Resets in \(countdown)")
        } else if needsAttention(snapshot),
                  limit.usageLimit.resetCountdownText(now: now) == "now" {
            parts.append("Reset due")
        }
        return parts.joined(separator: " · ")
    }

    private static func attentionRank(for snapshot: ProviderSnapshot) -> Int {
        if snapshot.authNotice != nil { return 1_000 }
        return (snapshot.band?.severityRank ?? -1) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.lg) {
            OverviewSummaryStrip(
                snapshots: snapshots,
                tightestLimit: tightestLimit,
                estimatedCost: costSummary?.formattedTotalCost,
                formattedTokens: UsageFormat.tokens(costSummary?.totalTokens ?? 0)
            )

            if snapshots.isEmpty {
                DashboardCard(title: "Providers") {
                    Text("Enable providers in Settings to start tracking quotas.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                overviewProviderList
            }
        }
    }

    private var overviewProviderList: some View {
        let sorted = Self.sortedForOverview(snapshots)
        let attention = sorted.filter(Self.needsAttention)
        let healthy = sorted.filter { !Self.needsAttention($0) }

        return VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
            if !attention.isEmpty {
                OverviewProviderGroup(
                    title: "Needs attention",
                    snapshots: attention,
                    onSelectProvider: onSelectProvider
                )
            }

            if !healthy.isEmpty {
                OverviewProviderGroup(
                    title: attention.isEmpty ? "Providers" : "Healthy",
                    snapshots: healthy,
                    onSelectProvider: onSelectProvider
                )
            }
        }
    }
}

private struct OverviewProviderGroup: View {
    let title: String
    let snapshots: [ProviderSnapshot]
    let onSelectProvider: (ProviderSnapshot.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(spacing: MeterBarTheme.Spacing.sm) {
                ForEach(snapshots) { snapshot in
                    Button {
                        onSelectProvider(snapshot.id)
                    } label: {
                        OverviewProviderRow(snapshot: snapshot)
                    }
                    .buttonStyle(ProviderCardButtonStyle())
                    .accessibilityHint("Open \(snapshot.title) quota details")
                }
            }
        }
    }
}

private struct OverviewProviderRow: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        TimelineView(
            .periodic(
                from: ResetCountdownSchedule.anchor,
                by: ResetCountdownSchedule.interval
            )
        ) { timeline in
            DashboardTile(padding: .popover) {
                HStack(spacing: 10) {
                    ProviderLogoView(
                        kind: snapshot.logoKind,
                        size: 18,
                        foregroundColor: snapshot.accentColor
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(snapshot.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            ProviderCardStatusLabel(snapshot: snapshot)
                        }

                        Text(DashboardOverviewSection.detailLine(for: snapshot, now: timeline.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    CardDisclosureChevron()
                }
            }
        }
    }
}

private struct OverviewSummaryStrip: View {
    let snapshots: [ProviderSnapshot]
    let tightestLimit: SnapshotLimit?
    let estimatedCost: String?
    let formattedTokens: String

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
