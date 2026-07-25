import MeterBarShared
import SwiftUI

// Costs page extracted from UsageDashboardView.swift (C1 split). Pure move; the
// cost-window trailing status string is lifted to a static so it can be asserted
// without hosting the page.

struct DashboardCostsSection: View {
    private let summary: CostSummary?
    private let quotaSnapshot: (ServiceType) -> ProviderSnapshot?

    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared

    init(
        summary: CostSummary?,
        quotaSnapshot: @escaping (ServiceType) -> ProviderSnapshot?
    ) {
        self.summary = summary
        self.quotaSnapshot = quotaSnapshot
    }

    /// Trailing status for the 30-day spend card. A full scan outranks the
    /// missing-day top-up because it supersedes it.
    static func refreshStatusText(isScanning: Bool, isRefreshingMissingDays: Bool) -> String? {
        if isScanning {
            return "Scanning..."
        }
        if isRefreshingMissingDays {
            return "Updating..."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CostOverviewStatusCard(
                summary: summary,
                isScanning: costTracker.isScanning,
                isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                formattedTokens: UsageFormat.tokens(summary?.totalTokens ?? 0)
            )

            LifetimeCostSummaryCard(
                summary: summary?.lifetime,
                isScanning: costTracker.isRefreshInProgress
            )

            costTrendCard

            if let summary, !summary.dailyUsage.isEmpty {
                DashboardCard(title: "Daily Details", trailing: "Last 30 days") {
                    DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                }
            }

            if let summary, !summary.costs.isEmpty {
                ForEach(summary.costs) { cost in
                    ProviderCostBreakdown(
                        cost: cost,
                        quotaSnapshot: quotaSnapshot(cost.provider)
                    )
                }
            } else {
                DashboardCard(title: "No Local Logs Found") {
                    Text("Run a local scan to load 30-day token history.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if apiUsageStore.hasAnyAuthenticated {
                DashboardCard(title: "Estimated API cost") {
                    ApiUsageSection(store: apiUsageStore, embedded: true)
                }
            }
        }
        .task {
            if apiUsageStore.hasAnyAuthenticated, !apiUsageStore.isLoading {
                await apiUsageStore.refresh()
            }
        }
    }

    private var costTrendCard: some View {
        DashboardCard(
            title: "30 Day Spend",
            trailing: Self.refreshStatusText(
                isScanning: costTracker.isScanning,
                isRefreshingMissingDays: costTracker.isRefreshingMissingDays
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Local subscription logs are estimated using API token rates "
                        + "so Codex and Claude can be compared."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let summary {
                    let presentation = CostChartPresentation(summary: summary)
                    ZStack {
                        if presentation.hasSpend {
                            CostSpendCharts(presentation: presentation)
                                .opacity(costTracker.isScanning ? 0.42 : 1)
                        } else {
                            EmptyStateCard(
                                systemImage: "chart.bar.xaxis",
                                title: "No spend in this window",
                                message: "No billable Claude or Codex usage was found in the last 30 days."
                            )
                        }

                        if costTracker.isScanning {
                            CostScanProgressBadge(compact: false)
                        }
                    }
                } else if costTracker.isScanning {
                    CostScanLoadingChart(compact: false)
                        .frame(height: 220)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run a local scan to load 30-day token history.")
                            .foregroundColor(.secondary)
                        Button {
                            Task {
                                await costTracker.scanCosts(days: 30)
                            }
                        } label: {
                            Label("Scan 30 Days", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(costTracker.isRefreshInProgress)
                    }
                    .frame(height: 220, alignment: .center)
                }
            }
        }
    }
}
