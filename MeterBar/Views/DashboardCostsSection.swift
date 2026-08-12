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

    /// The page-wide 7/30-day reporting window. Presentation-only: both windows
    /// are cut from the same cached 30-day scan, so flipping never rescans —
    /// the 7-day view just draws a quarter of the marks.
    @AppStorage(StorageKeys.costsWindowDays)
    private var costsWindowDays = CostWindowSelection.month.rawValue

    private var windowSelection: CostWindowSelection {
        CostWindowSelection(rawValue: costsWindowDays) ?? .month
    }

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
            windowPicker

            // The two headline figures answer the same question over different
            // windows, so they read as a pair. `maxHeight: .infinity` on both,
            // with the row fixed to its intrinsic height, stretches the shorter
            // card to the taller one instead of leaving it ending mid-air.
            HStack(alignment: .top, spacing: MeterBarTheme.Spacing.sm) {
                CostOverviewStatusCard(
                    summary: summary,
                    isScanning: costTracker.isScanning,
                    isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                    formattedTokens: UsageFormat.tokens(summary?.totalTokens ?? 0),
                    windowSelection: windowSelection
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                LifetimeCostSummaryCard(
                    summary: summary?.lifetime,
                    isScanning: costTracker.isRefreshInProgress
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)

            costTrendCard

            TokenActivityCard(
                summary: summary,
                windowSelection: windowSelection,
                isScanning: costTracker.isScanning,
                isScanDisabled: costTracker.isRefreshInProgress,
                scan: { Task { await costTracker.scanCosts(days: 30) } }
            )

            // Directly under the spend chart, because it answers the question
            // the chart's absence of Cursor raises. Hidden entirely when no
            // request-denominated provider has been polled — an empty card
            // would read as "measured nothing".
            let polledUsage = PolledRequestSeriesPresentation(
                ledger: costTracker.usageLedger,
                requestedDays: windowSelection.dayCount()
            )
            if !polledUsage.isEmpty {
                PolledUsageCard(presentation: polledUsage)
            }

            if let summary, !summary.dailyUsage.isEmpty {
                let windowStart = windowSelection.startDate()
                let windowRows = summary.dailyUsage.filter { $0.date >= windowStart }
                if !windowRows.isEmpty {
                    DashboardCard(title: "Daily Details", trailing: windowSelection.subtitle) {
                        DailyUsageBreakdownList(dailyUsage: windowRows)
                    }
                }
            }

            if let summary, !summary.costs.isEmpty {
                // Narrower windows re-cut provider cards to the same days as
                // the charts. A provider with no spend inside the window drops
                // out instead of showing 30-day numbers under a 7-day heading.
                let narrowedWindow = windowSelection == .month
                    ? nil
                    : windowSelection.costWindow(from: summary)
                ForEach(summary.costs) { cost in
                    let providerWindow = narrowedWindow?.providers.first { $0.provider == cost.provider }
                    if narrowedWindow == nil || providerWindow != nil {
                        ProviderCostBreakdown(
                            cost: cost,
                            quotaSnapshot: quotaSnapshot(cost.provider),
                            window: providerWindow,
                            windowSubtitle: providerWindow != nil ? windowSelection.subtitle : nil
                        )
                    }
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
            // One small JSON read, no log scan. The provider refresh cycle
            // appends to this artifact between scans, so the copy loaded at
            // launch is stale by the time the Costs page opens.
            costTracker.refreshUsageLedger()
            if apiUsageStore.hasAnyAuthenticated, !apiUsageStore.isLoading {
                await apiUsageStore.refresh()
            }
        }
    }

    /// One page-wide window control, trailing-aligned above the cards it
    /// governs. A segmented picker rather than per-card toggles so every cost
    /// surface below always reports the same days.
    private var windowPicker: some View {
        HStack {
            Spacer()
            Picker("Reporting window", selection: $costsWindowDays) {
                ForEach(CostWindowSelection.allCases) { window in
                    Text(window.pickerLabel).tag(window.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Reporting window")
        }
    }

    private var costTrendCard: some View {
        DashboardCard(
            title: windowSelection.spendCardTitle,
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
                    let presentation = CostChartPresentation(
                        summary: summary,
                        requestedDays: windowSelection.dayCount(),
                        windowStart: windowSelection.startDate()
                    )
                    ZStack {
                        if presentation.hasSpend {
                            CostSpendCharts(presentation: presentation)
                                .opacity(costTracker.isScanning ? 0.42 : 1)
                        } else {
                            EmptyStateCard(
                                systemImage: "chart.bar.xaxis",
                                title: "No spend in this window",
                                message: "No billable usage was found in the \(windowSelection.subtitle.lowercased())."
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
