import AppKit
import SwiftUI
import MeterBarShared

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: UsageDashboardView())
            // Surface the SwiftUI NavigationSplitView title and toolbar through the
            // AppKit window while the full-size content view keeps the sidebar glass
            // running behind the titlebar.
            hostingController.sceneBridgingOptions = [.all]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MeterBar Usage"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            // Unified transparent chrome so the native toolbar/titlebar glass
            // reads as one surface with the sidebar (MacSweep-style native look).
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case limits = "Limits"
    case costs = "Costs"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .limits:
            return "chart.bar.fill"
        case .costs:
            return "dollarsign.circle.fill"
        case .settings:
            return "gearshape.fill"
        }
    }
}

struct UsageDashboardView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared

    @State private var selectedSection: DashboardSection = .overview
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var activeSection: DashboardSection { selectedSection }

    private var overviewGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
            count: 2
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack {
                // Keep the detail fill out of the titlebar area so the native
                // toolbar glass shows there instead of a flat content background.
                MeterBarDetailBackground()
                    .ignoresSafeArea(edges: [.horizontal, .bottom])

                detailContent
            }
            .navigationTitle(activeSection.rawValue)
            .navigationSubtitle(sectionSubtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await refreshDashboard() }
                    } label: {
                        RefreshingIcon(isRefreshing: isRefreshButtonAnimating)
                    }
                    .help(isRefreshButtonAnimating ? "Refreshing usage" : "Refresh usage")
                    .disabled(isRefreshButtonDisabled)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await refreshCostsIfMissingDays()
        }
        .onChange(of: selectedSection) {
            Task { await refreshCostsIfMissingDays() }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            ForEach(DashboardSection.allCases) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section)
            }

            Section("Local Sources") {
                if enabledSourceLabels.isEmpty {
                    Label("No sources enabled", systemImage: "circle")
                } else {
                    ForEach(enabledSourceLabels, id: \.self) { label in
                        Label(label, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
        // No background overrides: the native sidebar owns its glass material,
        // section rendering, and selected-row highlight. Stacking a custom
        // `.glassEffect` here would double up on the system material.
    }

    private var detailContent: some View {
        // Keep a real scroll backing in the detail column while the sidebar
        // remains a plain native List.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch activeSection {
                case .overview:
                    overviewContent
                case .limits:
                    limitsContent
                case .costs:
                    costsContent
                case .settings:
                    settingsContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                iconName: overviewStatusIconName,
                color: overviewBand?.color ?? .secondary
            )

            LazyVGrid(columns: overviewGridColumns, alignment: .leading, spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot)
                }

                CostOverviewStatusCard(
                    summary: visibleCostSummary,
                    isScanning: costTracker.isScanning,
                    isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                    formattedTokens: UsageFormat.tokens(visibleCostSummary?.totalTokens ?? 0)
                )
            }
            .frame(maxWidth: .infinity)

            if apiUsageStore.hasAnyAuthenticated {
                DashboardCard(title: "Organization API Spend", trailing: "") {
                    ApiUsageSection(store: apiUsageStore, embedded: true)
                }
            }

            DashboardCard(title: "Last 30 Days", trailing: costRefreshStatusText) {
                costScanChart(height: 180, compact: true)
            }
        }
        .task {
            await apiUsageStore.refresh()
        }
    }

    private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All Quota Windows")
                    .font(.title3)
                    .bold()
                Spacer()
                if dataManager.isLoading {
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if providerSnapshots.isEmpty {
                DashboardCard(title: "No Quota Windows") {
                    Text("Enable providers in Settings to show quota windows.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(providerSnapshots) { snapshot in
                    ProviderLimitsCard(snapshot: snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "30 Day API-Rate Token Spend", trailing: costRefreshStatusText) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(
                        "Local subscription logs are estimated using API token rates "
                            + "so Codex and Claude can be compared."
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if costTracker.isScanning {
                        costScanChart(height: 220, compact: false, showsProgressBadge: false)
                    } else if let summary = visibleCostSummary {
                        DailyUsageChart(dailyUsage: summary.dailyUsage)
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
                            .buttonStyle(.bordered)
                            .disabled(costTracker.isRefreshInProgress)
                        }
                        .frame(height: 220, alignment: .center)
                    }

                    Divider()

                    if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                        DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                        Divider()
                    }

                    if let summary = visibleCostSummary, !summary.costs.isEmpty {
                        ForEach(summary.costs) { cost in
                            ProviderCostBreakdown(
                                cost: cost,
                                quotaSnapshot: providerSnapshot(for: cost.provider)
                            )
                        }
                    } else {
                        Text("No enabled provider token logs found yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .overlay {
                if costTracker.isScanning, visibleCostSummary != nil {
                    CostRefreshLockOverlay()
                }
            }
        }
    }

    private func costScanChart(height: CGFloat, compact: Bool, showsProgressBadge: Bool = true) -> some View {
        ZStack {
            if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                DailyUsageChart(dailyUsage: summary.dailyUsage)
                    .opacity(costTracker.isScanning ? 0.42 : 1)
            } else if costTracker.isScanning {
                CostScanLoadingChart(compact: compact)
            } else {
                DailyUsageChart(dailyUsage: [])
            }

            if showsProgressBadge, costTracker.isScanning, visibleCostSummary?.dailyUsage.isEmpty == false {
                CostScanProgressBadge(compact: compact)
            }
        }
        .frame(height: height)
    }

    private var settingsContent: some View {
        SettingsView(embeddedInDashboard: true)
            .frame(maxWidth: .infinity, minHeight: 520, alignment: .leading)
    }

    private var providerSnapshots: [ProviderSnapshot] {
        // Same builder the popover uses; the dashboard only renders providers
        // that have reported metrics.
        ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: dataManager.metrics,
            claudeAccounts: claudeAccountStore.accounts,
            claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
            enabledServices: providerVisibility.enabledServices,
            claudeCodeHasAccess: claudeCodeService.hasAccess,
            codexCliHasAccess: codexCliService.hasAccess,
            cursorHasAccess: cursorService.hasAccess
        ))
        .filter(\.hasMetrics)
    }

    /// The snapshot for a provider in the Costs panel — prefers an exhausted
    /// one so the cost card can surface when that provider's quota resets.
    private func providerSnapshot(for service: ServiceType) -> ProviderSnapshot? {
        let matches = providerSnapshots.filter { $0.service == service }
        return matches.first(where: \.hasExhaustedLimit) ?? matches.first
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var enabledSourceLabels: [String] {
        var labels: [String] = []
        if providerVisibility.isEnabled(.codexCli) {
            labels.append("Codex logs")
        }
        if providerVisibility.isEnabled(.claudeCode) {
            labels.append("Claude JSONL")
        }
        if providerVisibility.isEnabled(.cursor) {
            labels.append("Cursor local state")
        }
        return labels
    }

    private var tightestLimit: SnapshotLimit? {
        providerSnapshots.tightestLimit
    }

    private var overviewBand: QuotaBand? {
        tightestLimit.map { QuotaBand.forPercentLeft($0.percentLeft) }
    }

    private var overviewStatusTitle: String {
        guard !providerSnapshots.isEmpty else { return "No sources enabled" }
        guard let overviewBand else { return "Waiting for usage" }
        return overviewBand.overviewTitle
    }

    private var overviewStatusIconName: String {
        // Neutral states (no providers enabled / no usage yet) should not show
        // the healthy green shield, which falsely implies tracked quotas look good.
        overviewBand?.iconName ?? "circle.dashed"
    }

    private var overviewStatusDetail: String {
        guard !providerSnapshots.isEmpty else {
            return "Enable providers in Settings to show quota status."
        }
        guard let tightestLimit else {
            return "Refresh to load enabled provider status."
        }
        if tightestLimit.percentLeft <= 0 {
            return "\(tightestLimit.title) is out until reset. "
                + "Tracking \(providerSnapshots.count) local provider sources."
        }
        return "\(tightestLimit.title) has \(tightestLimit.percentLeft)% left. "
            + "Tracking \(providerSnapshots.count) local provider sources."
    }

    private var sectionSubtitle: String {
        switch activeSection {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .costs:
            return "Local 30-day token spend"
        case .settings:
            return "Accounts, refresh, and local sources"
        }
    }

    private var costRefreshStatusText: String? {
        if costTracker.isScanning {
            return "Scanning..."
        }
        if costTracker.isRefreshingMissingDays {
            return "Updating..."
        }
        return nil
    }

    private var isRefreshButtonDisabled: Bool {
        isRefreshButtonAnimating
    }

    private var isRefreshButtonAnimating: Bool {
        switch activeSection {
        case .costs:
            return costTracker.isRefreshInProgress
        case .overview, .limits, .settings:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        if activeSection == .costs {
            await costTracker.scanCosts(days: 30)
        } else {
            await dataManager.refreshAll()
        }
    }

    private func refreshCostsIfMissingDays() async {
        guard activeSection == .overview || activeSection == .costs else { return }
        await costTracker.refreshMissingDaysInBackground(days: 30)
    }
}

private let overviewTileMinHeight: CGFloat = 220

private struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let iconName: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 46, height: 46)
                Image(systemName: iconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .dashboardCardBackground()
    }
}

private struct ProviderOverviewStatusCard: View {
    let snapshot: ProviderSnapshot

    private var statusText: String {
        snapshot.band?.shortLabel ?? "No data"
    }

    private var statusColor: Color {
        snapshot.band?.color ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: snapshot.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(updatedText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.limits) { limit in
                        DashboardLimitRow(limit: limit, accentColor: snapshot.accentColor)
                    }
                }
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: overviewTileMinHeight,
            alignment: .topLeading
        )
        .dashboardCardBackground()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

private struct CostOverviewStatusCard: View {
    let summary: CostSummary?
    let isScanning: Bool
    let isRefreshingMissingDays: Bool
    let formattedTokens: String

    private var subtitle: String {
        if isScanning { return "Scanning local logs" }
        if isRefreshingMissingDays { return "Updating…" }
        return "Last 30 days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MeterBarTheme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("API-Rate Estimate")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let formattedTotalCost = summary?.formattedTotalCost {
                Text(formattedTotalCost)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                Text("Scan needed")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 7) {
                HStack {
                    Text("Tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formattedTokens)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                HStack {
                    Text("Providers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(summary?.costs.count ?? 0)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: overviewTileMinHeight,
            alignment: .topLeading
        )
        .dashboardCardBackground()
    }
}

private struct ProviderLimitsCard: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderTitle(
                    title: snapshot.title,
                    logoKind: snapshot.logoKind,
                    color: snapshot.accentColor,
                    font: .title3
                )
                Spacer()
                Text(updatedText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if snapshot.limits.isEmpty {
                Text("No quota windows reported")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(snapshot.limits) { limit in
                    DashboardLimitRow(limit: limit, accentColor: snapshot.accentColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }

    private var updatedText: String {
        guard let updatedAt = snapshot.updatedAt else { return "No data" }
        return "Updated \(UsageFormat.relative(updatedAt))"
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3)
                    .bold()
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }
}

private struct ProviderTitle: View {
    let title: String
    let logoKind: ProviderLogoKind
    let color: Color
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: logoKind, size: 18, foregroundColor: color)
            Text(title)
                .font(font)
                .fontWeight(.semibold)
        }
    }
}

private struct DashboardLimitRow: View {
    let limit: SnapshotLimit
    let accentColor: Color

    private var isOut: Bool {
        limit.percentLeft <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(isOut ? "Out" : "\(limit.percentLeft)% left")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
            }

            UsageBar(
                usedPercentage: limit.usedPercent,
                accentColor: accentColor,
                pace: limit.usageLimit.pace(),
                paceContext: limit.paceContext
            )

            HStack {
                Text("\(Int(limit.usedPercent.rounded()))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let pace = limit.usageLimit.pace() {
                    Text(pace.leftLabel)
                        .font(.caption)
                        .foregroundColor(paceLabelColor(pace))
                }
                Spacer()
                if limit.usageLimit.resetTime != nil {
                    ResetCountdownLabel(
                        title: nil,
                        limit: limit.usageLimit,
                        font: .caption,
                        foregroundColor: .secondary,
                        iconSize: 10
                    )
                }
            }
        }
    }

    private func paceLabelColor(_ pace: UsagePace) -> Color {
        if pace.isExhausted {
            return MeterBarTheme.danger
        }
        switch pace.stage {
        case .reserve:
            return MeterBarTheme.success
        case .deficit:
            return MeterBarTheme.warning
        case .onPace:
            return .secondary
        }
    }
}

private struct CostScanLoadingChart: View {
    let compact: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private let barCount = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let spacing: CGFloat = compact ? 4 : 5
                let labelHeight: CGFloat = compact ? 34 : 44
                let chartHeight = max(42, proxy.size.height - labelHeight)
                let barWidth = max(4, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
                let time = timeline.date.timeIntervalSinceReferenceDate
                let sweepWidth = max(42, proxy.size.width * 0.18)
                let sweepProgress = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8)
                let sweepX = sweepProgress * (proxy.size.width + sweepWidth) - sweepWidth

                VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning local logs")
                            .font(compact ? .caption : .subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("30 days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ZStack(alignment: .leading) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(0..<barCount, id: \.self) { index in
                                let seed = Double(((index * 17) % 11) + 2) / 13
                                let wave = reduceMotion ? 0.5 : (sin((time * 3.2) + Double(index) * 0.55) + 1) / 2
                                let height = chartHeight * CGFloat(0.14 + (seed * 0.44) + (wave * 0.28))

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                MeterBarTheme.codexAccent.opacity(0.18 + wave * 0.16),
                                                MeterBarTheme.cursorAccent.opacity(0.16 + seed * 0.20)
                                            ],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: barWidth, height: max(4, height))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        if !reduceMotion {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Color.primary.opacity(0.22), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: sweepWidth, height: chartHeight)
                                .offset(x: sweepX)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    if !compact {
                        Text("Parsing Claude and Codex sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct CostScanProgressBadge: View {
    let compact: Bool

    var body: some View {
        VStack {
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(compact ? "Scanning..." : "Updating local scan")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, compact ? 9 : 11)
                .padding(.vertical, compact ? 6 : 8)
                .glassEffect(.regular, in: .capsule)

                Spacer()
            }

            Spacer()
        }
        .padding(compact ? 8 : 10)
    }
}

private struct CostRefreshLockOverlay: View {
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .opacity(0.62)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0), including: .all)

            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing costs")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Text("Scanning local token logs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing costs")
        .accessibilityHint("Cost results are locked until the local scan finishes.")
    }
}

private struct DailyUsageChart: View {
    let dailyUsage: [DailyTokenUsage]
    let daysToShow: Int

    private let barSpacing: CGFloat = 4
    private let labelHeight: CGFloat = 22
    private let legendHeight: CGFloat = 18

    // Precomputed once at init instead of on every SwiftUI body access. The
    // grouping + 30-day date arithmetic was previously re-run many times per
    // render (from body, visibleProviders, maxTokens, barWidth, barHeight).
    private let days: [DailyUsageDay]

    init(dailyUsage: [DailyTokenUsage], daysToShow: Int = 30) {
        self.dailyUsage = dailyUsage
        self.daysToShow = daysToShow
        self.days = Self.buildDays(from: dailyUsage, daysToShow: daysToShow)
    }

    private static let providerOrder: [ServiceType] = [.claudeCode, .codexCli, .cursor]

    private static func buildDays(from dailyUsage: [DailyTokenUsage], daysToShow: Int) -> [DailyUsageDay] {
        let calendar = Calendar.current
        let normalizedDaysToShow = max(1, daysToShow)
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(normalizedDaysToShow - 1), to: endDate) ?? endDate
        let grouped = Dictionary(grouping: dailyUsage) { calendar.startOfDay(for: $0.date) }

        return (0..<normalizedDaysToShow).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }

            let rows = grouped[date] ?? []
            let segments = providerOrder.compactMap { provider -> DailyUsageProviderSegment? in
                let providerRows = rows.filter { $0.provider == provider }
                let tokens = providerRows.reduce(0) { $0 + $1.totalTokens }
                guard tokens > 0 else { return nil }

                return DailyUsageProviderSegment(
                    provider: provider,
                    tokens: tokens,
                    cost: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
                )
            }

            return DailyUsageDay(
                date: date,
                segments: segments,
                cost: rows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
    }

    private var visibleProviders: [ServiceType] {
        Self.providerOrder.filter { provider in
            days.contains { day in
                day.segments.contains { $0.provider == provider }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if days.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No token history found for the last 30 days.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                legend

                GeometryReader { proxy in
                    let width = barWidth(totalWidth: proxy.size.width)
                    let chartHeight = max(40, proxy.size.height - labelHeight)

                    VStack(spacing: 5) {
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(days) { day in
                                StackedDailyUsageColumn(
                                    day: day,
                                    width: width,
                                    height: barHeight(totalHeight: chartHeight, tokens: day.totalTokens),
                                    maxHeight: chartHeight,
                                    helpText: helpText(for: day),
                                    colorForProvider: color(for:)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

                        HStack(alignment: .top, spacing: barSpacing) {
                            ForEach(days.indices, id: \.self) { index in
                                DailyUsageDateLabel(
                                    date: days[index].date,
                                    width: width,
                                    showsMonth: shouldShowMonth(at: index)
                                )
                            }
                        }
                        .frame(height: labelHeight, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(visibleProviders, id: \.self) { provider in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: provider))
                        .frame(width: 8, height: 8)
                    Text(provider.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: legendHeight, alignment: .leading)
    }

    private var maxTokens: Int {
        max(days.map(\.totalTokens).max() ?? 1, 1)
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        let gapsWidth = CGFloat(max(0, days.count - 1)) * barSpacing
        return max(4, (totalWidth - gapsWidth) / CGFloat(max(1, days.count)))
    }

    private func barHeight(totalHeight: CGFloat, tokens: Int) -> CGFloat {
        guard tokens > 0 else { return 2 }
        return max(4, totalHeight * CGFloat(tokens) / CGFloat(maxTokens))
    }

    private func shouldShowMonth(at index: Int) -> Bool {
        guard days.indices.contains(index) else { return false }
        if index == 0 { return true }

        return Calendar.current.component(.day, from: days[index].date) == 1
    }

    private func helpText(for day: DailyUsageDay) -> String {
        var lines = [
            DashboardDateFormat.medium(day.date),
            "\(UsageFormat.tokens(day.totalTokens)) tokens",
            UsageFormat.cost(day.cost)
        ]

        if day.segments.isEmpty {
            lines.append("No tracked provider usage")
        } else {
            lines.append("")
            for segment in day.segments {
                lines.append(
                    "\(segment.provider.displayName): "
                        + "\(UsageFormat.tokens(segment.tokens)) · \(UsageFormat.cost(segment.cost))"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private func color(for provider: ServiceType) -> Color {
        MeterBarTheme.accent(for: provider)
    }
}

private struct StackedDailyUsageColumn: View {
    let day: DailyUsageDay
    let width: CGFloat
    let height: CGFloat
    let maxHeight: CGFloat
    let helpText: String
    let colorForProvider: (ServiceType) -> Color

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if day.totalTokens > 0 {
                VStack(spacing: 0) {
                    ForEach(day.segments.reversed()) { segment in
                        Rectangle()
                            .fill(colorForProvider(segment.provider))
                            .frame(height: segmentHeight(segment))
                    }
                }
                .frame(width: width, height: height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: width, height: 2)
            }
        }
        .frame(width: width, height: maxHeight, alignment: .bottom)
        .help(helpText)
    }

    private func segmentHeight(_ segment: DailyUsageProviderSegment) -> CGFloat {
        guard day.totalTokens > 0 else { return 0 }
        return max(1, height * CGFloat(segment.tokens) / CGFloat(day.totalTokens))
    }
}

private struct DailyUsageDateLabel: View {
    let date: Date
    let width: CGFloat
    let showsMonth: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(dayText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(showsMonth ? monthText : "")
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: 20, alignment: .top)
        .help(fullDateText)
    }

    private var dayText: String {
        String(Calendar.current.component(.day, from: date))
    }

    private var monthText: String {
        DashboardDateFormat.month(date)
    }

    private var fullDateText: String {
        DashboardDateFormat.medium(date)
    }
}

private struct DailyUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let segments: [DailyUsageProviderSegment]
    let cost: Double

    var totalTokens: Int {
        segments.reduce(0) { $0 + $1.tokens }
    }
}

private struct DailyUsageProviderSegment: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let tokens: Int
    let cost: Double
}

private struct DailyUsageBreakdownList: View {
    let dailyUsage: [DailyTokenUsage]

    @State private var expandedDayIDs: Set<Date> = []

    private var days: [DailyProviderUsageDay] {
        let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { day, rows in
            DailyProviderUsageDay(date: day, providers: providerSummaries(from: rows))
        }
        .filter { $0.totalTokens > 0 }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily Details")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Last 30 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(days) { day in
                    DailyUsageDetailRow(
                        day: day,
                        isExpanded: expandedDayIDs.contains(day.id),
                        toggle: { toggleExpansion(for: day.id) }
                    )
                }
            }
        }
    }

    private func toggleExpansion(for dayID: Date) {
        withAnimation(.snappy(duration: 0.18)) {
            if expandedDayIDs.contains(dayID) {
                expandedDayIDs.remove(dayID)
            } else {
                expandedDayIDs.insert(dayID)
            }
        }
    }

    private func providerSummaries(from rows: [DailyTokenUsage]) -> [DailyProviderUsageSummary] {
        let grouped = Dictionary(grouping: rows, by: \.provider)
        return grouped.map { provider, providerRows in
            DailyProviderUsageSummary(
                provider: provider,
                inputTokens: providerRows.reduce(0) { $0 + $1.inputTokens },
                outputTokens: providerRows.reduce(0) { $0 + $1.outputTokens },
                cacheReadTokens: providerRows.reduce(0) { $0 + $1.cacheReadTokens },
                estimatedCostUSD: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
            )
        }
        .sorted { lhs, rhs in
            if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.estimatedCostUSD > rhs.estimatedCostUSD
        }
    }
}

private struct DailyProviderUsageDay: Identifiable {
    var id: Date { date }
    let date: Date
    let providers: [DailyProviderUsageSummary]

    var totalTokens: Int {
        providers.reduce(0) { $0 + $1.totalTokens }
    }

    var estimatedCostUSD: Double {
        providers.reduce(0) { $0 + $1.estimatedCostUSD }
    }
}

private struct DailyProviderUsageSummary: Identifiable {
    var id: ServiceType { provider }
    let provider: ServiceType
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let estimatedCostUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens
    }
}

private struct DailyUsageDetailRow: View {
    let day: DailyProviderUsageDay
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(dateLabel(day.date))
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(providerCountLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(UsageFormat.tokens(day.totalTokens)) tokens")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(UsageFormat.cost(day.estimatedCostUSD))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(isExpanded ? "Collapse day details" : "Show day details")

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(day.providers) { provider in
                        DailyProviderUsageSummaryRow(provider: provider)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var providerCountLabel: String {
        let count = day.providers.count
        return count == 1 ? "1 source" : "\(count) sources"
    }

    private var accessibilitySummary: String {
        "\(dateLabel(day.date)), \(UsageFormat.tokens(day.totalTokens)) tokens, "
            + "\(UsageFormat.cost(day.estimatedCostUSD))"
    }

    private func dateLabel(_ date: Date) -> String {
        DashboardDateFormat.weekdayMonthDay(date)
    }
}

private struct DailyProviderUsageSummaryRow: View {
    let provider: DailyProviderUsageSummary

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogoView(
                kind: .forService(provider.provider),
                size: 14,
                foregroundColor: MeterBarTheme.accent(for: provider.provider)
            )
            Text(provider.provider.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .frame(width: 110, alignment: .leading)
            UsageDetailMetric(label: "Input", value: UsageFormat.tokens(provider.inputTokens))
            UsageDetailMetric(label: "Output", value: UsageFormat.tokens(provider.outputTokens))
            UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(provider.cacheReadTokens))
            Spacer()
            Text(UsageFormat.cost(provider.estimatedCostUSD))
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
}

private struct ProviderCostBreakdown: View {
    let cost: TokenCost
    var quotaSnapshot: ProviderSnapshot?

    private var logoKind: ProviderLogoKind {
        .forService(cost.provider)
    }

    private var logoColor: Color {
        MeterBarTheme.accent(for: cost.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProviderTitle(
                    title: cost.provider.displayName,
                    logoKind: logoKind,
                    color: logoColor,
                    font: .headline
                )
                Spacer()
                Text(cost.formattedCost)
                    .font(.title3)
                    .bold()
            }

            if let quotaSnapshot, quotaSnapshot.hasExhaustedLimit {
                BlockingLimitResetCounter(
                    windows: quotaSnapshot.resetWindows,
                    accentColor: logoColor
                )
            }

            HStack(spacing: 14) {
                CostMetric(label: "Tokens", value: cost.formattedTokens)
                CostMetric(label: "Input", value: UsageFormat.tokens(cost.inputTokens))
                CostMetric(label: "Output", value: UsageFormat.tokens(cost.outputTokens))
                CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
            }

            if !cost.modelBreakdowns.isEmpty {
                CostBreakdownSection(title: "Models", items: Array(cost.modelBreakdowns.prefix(6)))
            }

            if !cost.originBreakdowns.isEmpty {
                CostBreakdownSection(title: "Usage Origin", items: Array(cost.originBreakdowns.prefix(6)))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CostBreakdownSection: View {
    let title: String
    let items: [TokenUsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)

                    UsageDetailMetric(label: "Tokens", value: UsageFormat.tokens(item.totalTokens))
                    UsageDetailMetric(label: "Input", value: UsageFormat.tokens(item.inputTokens))
                    UsageDetailMetric(label: "Output", value: UsageFormat.tokens(item.outputTokens))
                    UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(item.cacheReadTokens))

                    Spacer()

                    Text(item.formattedCost)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}

private struct CostMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageDetailMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 58, alignment: .leading)
    }
}

/// Cached date formatters for the dashboard. `DateFormatter` is expensive to
/// allocate, so the daily chart/labels (30+ per render) share these instances.
private enum DashboardDateFormat {
    private static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let weekdayMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    static func medium(_ date: Date) -> String { mediumDate.string(from: date) }
    static func month(_ date: Date) -> String { month.string(from: date) }
    static func weekdayMonthDay(_ date: Date) -> String { weekdayMonthDay.string(from: date) }
}

private extension View {
    /// Dashboard content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the dashboard and popover cards stay visually identical.
    func dashboardCardBackground() -> some View {
        meterBarCardSurface()
    }
}
