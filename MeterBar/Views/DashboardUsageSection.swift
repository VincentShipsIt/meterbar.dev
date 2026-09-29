import MeterBarShared
import SwiftUI

// The Usage page (issue #593): what used to be the Costs and Optimize pages, drawn
// once. One reporting window drives a headline strip, one time series, one
// breakdown table and an insights column, all cut from a single `UsageReport`.

struct DashboardUsageSection: View {
    private let summary: CostSummary?

    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared
    @StateObject private var iCloudSettings = ICloudUsageSettingsStore.shared
    @StateObject private var iCloudAggregation = ICloudUsageAggregationService.shared

    /// The page-wide 7/30-day/month-to-date reporting window. Presentation-only:
    /// every window is cut from the same cached scan, so flipping never rescans.
    @AppStorage(StorageKeys.costsWindowDays)
    private var costsWindowDays = CostWindowSelection.month.rawValue

    private var windowSelection: CostWindowSelection {
        CostWindowSelection(rawValue: costsWindowDays) ?? .month
    }

    init(summary: CostSummary?) {
        self.summary = summary
    }

    /// Trailing status for the chart card. A full scan outranks the missing-day
    /// top-up because it supersedes it.
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

            if costTracker.isRefreshInProgress, let progress = costTracker.scanProgress {
                CostScanScopeBanner(progress: progress)
            }

            if let summary, !summary.costs.isEmpty || !summary.dailyUsage.isEmpty {
                usageContent(for: summary)
            } else {
                emptyState
            }
        }
        .task {
            // One small JSON read, no log scan. The provider refresh cycle
            // appends to this artifact between scans, so the copy loaded at
            // launch is stale by the time the Usage page opens.
            costTracker.refreshUsageLedger()
            if apiUsageStore.hasAnyAuthenticated, !apiUsageStore.isLoading {
                await apiUsageStore.refresh()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func usageContent(for summary: CostSummary) -> some View {
        let report = UsageReport(
            summary: summary,
            selection: windowSelection,
            compressedCodexRollouts: costTracker.scanProgress?.codexCompressedRolloutCount ?? 0
        )

        UsageColumnsLayout {
            VStack(alignment: .leading, spacing: 14) {
                mainColumn(report: report, summary: summary)
            }

            UsageInsightsColumn(report: report, extraNotes: deviceNotes)
        }
    }

    @ViewBuilder
    private func mainColumn(report: UsageReport, summary: CostSummary) -> some View {
        if report.hasData {
            UsageHeadlineStrip(report: report)
            UsageTimeSeriesCard(
                report: report,
                statusText: Self.refreshStatusText(
                    isScanning: costTracker.isScanning,
                    isRefreshingMissingDays: costTracker.isRefreshingMissingDays
                ),
                isScanning: costTracker.isScanning,
                scanProgress: costTracker.scanProgress
            )
            UsageBreakdownCard(report: report)
        } else {
            DashboardCard(title: "No usage in this window") {
                EmptyStateCard(
                    systemImage: "chart.bar.xaxis",
                    title: "Nothing recorded",
                    message: summary.dailyUsage.isEmpty
                        ? "This cached scan has no dated rows. Run a new scan to rebuild daily history."
                        : "No usage was found in the \(windowSelection.subtitle.lowercased())."
                )
            }
        }

        secondaryDetail(summary: summary)
    }

    /// Everything that is not the headline story: the hourly heatmap, polled
    /// request counts, the day-by-day list and the admin-key API cost.
    @ViewBuilder
    private func secondaryDetail(summary: CostSummary) -> some View {
        TokenActivityCard(
            summary: summary,
            windowSelection: windowSelection,
            isScanning: costTracker.isScanning,
            isScanDisabled: costTracker.isRefreshInProgress,
            scan: { Task { await costTracker.scanCosts(days: CostWindow.scanWindowDays) } }
        )

        // Answers the question the chart's absence of Cursor raises. Hidden
        // entirely when no request-denominated provider has been polled — an
        // empty card would read as "measured nothing".
        let polledUsage = PolledRequestSeriesPresentation(
            ledger: costTracker.usageLedger,
            requestedDays: windowSelection.dayCount()
        )
        if !polledUsage.isEmpty {
            PolledUsageCard(presentation: polledUsage)
        }

        let windowStart = windowSelection.startDate()
        let windowRows = summary.dailyUsage.filter { $0.date >= windowStart }
        if !windowRows.isEmpty {
            DashboardCard(title: "Daily Details", trailing: windowSelection.subtitle) {
                DailyUsageBreakdownList(dailyUsage: windowRows)
            }
        }

        if apiUsageStore.hasAnyAuthenticated {
            DashboardCard(title: "Estimated API cost") {
                ApiUsageSection(store: apiUsageStore, embedded: true)
            }
        }
    }

    /// With "All Macs" on, name the installations whose daily records the totals
    /// were combined from — the provider cards this page replaced carried that
    /// caption per provider.
    private var deviceNotes: [UsageDataNote] {
        guard iCloudSettings.showsAllMacs, let aggregate = iCloudAggregation.aggregate else { return [] }
        let start = windowSelection.startDate()
        let names = Set(ServiceType.allCases.flatMap { provider in
            aggregate.contributingDevices(for: provider, startingAt: start).map(\.name)
        })
        guard !names.isEmpty else { return [] }
        let note = UsageDataNote(
            id: "all-macs",
            severity: .info,
            text: "Combined from \(names.sorted().formatted(.list(type: .and))) via iCloud."
        )
        return [note]
    }

    // MARK: - Empty and first-scan states

    @ViewBuilder private var emptyState: some View {
        if costTracker.isScanning {
            DashboardCard(title: "Usage", trailing: "Scanning...") {
                CostScanLoadingChart(compact: false, progress: costTracker.scanProgress)
                    .frame(height: 220)
            }
        } else {
            DashboardCard(title: "No Local Logs Found") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(
                        "Run a local scan to see which models and workflows burn the most tokens, "
                            + "how well your cache is reused, and where you can trim spend."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                    Label(
                        "The scan reads your local Claude, Codex and Grok logs on-device. Only token totals "
                            + "and model names are analyzed — never prompt contents, and nothing is uploaded.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Button {
                        Task { await costTracker.scanCosts(days: CostWindow.scanWindowDays) }
                    } label: {
                        Label("Scan 30 Days", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(costTracker.isRefreshInProgress)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Window control

    /// One page-wide window control, trailing-aligned above everything it
    /// governs. A segmented picker rather than per-card toggles so every figure
    /// on the page always reports the same days.
    private var windowPicker: some View {
        HStack {
            if iCloudSettings.isEnabled {
                Toggle("All Macs", isOn: Binding(
                    get: { iCloudSettings.showsAllMacs },
                    set: { iCloudSettings.setShowsAllMacs($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(iCloudAggregation.aggregate == nil)
                .help("Combine compact daily usage rollups from your iCloud devices")
            }
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
}
