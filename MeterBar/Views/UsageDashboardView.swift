import AppKit
import SwiftUI

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
                MeterBarDetailBackground()
                    .ignoresSafeArea()

                detailContent
            }
            .navigationTitle(activeSection.rawValue)
            .navigationSubtitle(sectionSubtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await refreshDashboard() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh usage")
                    .disabled(isRefreshButtonDisabled)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            ForEach(DashboardSection.allCases) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        // Keep the sidebar system-owned. Custom backgrounds belong in the detail
        // pane so the native Liquid Glass sidebar material and selection remain intact.
        .safeAreaInset(edge: .bottom) { sourcesFooter }
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

    private var sourcesFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local Sources")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabledSourceLabels.isEmpty {
                Text("No sources enabled")
            } else {
                ForEach(enabledSourceLabels, id: \.self) { label in
                    Label(label, systemImage: "checkmark.circle.fill")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardStatusHero(
                title: overviewStatusTitle,
                detail: overviewStatusDetail,
                color: tightestWindowColor
            )

            LazyVGrid(columns: overviewGridColumns, alignment: .leading, spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    ProviderOverviewStatusCard(snapshot: snapshot)
                }

                CostOverviewStatusCard(
                    summary: visibleCostSummary,
                    isScanning: costTracker.isScanning,
                    formattedTokens: formattedTokenCount(visibleCostSummary?.totalTokens ?? 0)
                )
            }
            .frame(maxWidth: .infinity)

            DashboardCard(title: "Last 30 Days", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                costScanChart(height: 180, compact: true)
            }
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
                    ProviderLimitsCard(
                        snapshot: snapshot,
                        accentColor: color(for: snapshot.service),
                        updatedText: "Updated \(relativeDate(snapshot.lastUpdated))"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "30 Day API-Rate Token Spend", trailing: costTracker.isScanning ? "Scanning..." : nil) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Local subscription logs are estimated using API token rates so Codex and Claude can be compared.")
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
                            .disabled(costTracker.isScanning)
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
                            ProviderCostBreakdown(cost: cost)
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

    private var providerSnapshots: [DashboardProviderSnapshot] {
        var snapshots: [DashboardProviderSnapshot] = []

        if providerVisibility.isEnabled(.codexCli), let codex = dataManager.metrics[.codexCli] {
            snapshots.append(DashboardProviderSnapshot(title: "Codex", service: .codexCli, metrics: codex))
        }

        if providerVisibility.isEnabled(.claudeCode) {
            let claudeAccountMetrics = dataManager.claudeCodeAccountMetrics
            if !claudeAccountMetrics.isEmpty {
                for account in claudeAccountStore.accounts {
                    if let metrics = claudeAccountMetrics[account.id] {
                        snapshots.append(DashboardProviderSnapshot(
                            title: account.isDefault && claudeAccountStore.accounts.count == 1 ? "Claude" : account.name,
                            service: .claudeCode,
                            metrics: metrics
                        ))
                    }
                }
            } else if let claude = dataManager.metrics[.claudeCode] {
                snapshots.append(DashboardProviderSnapshot(title: "Claude", service: .claudeCode, metrics: claude))
            }
        }

        if providerVisibility.isEnabled(.cursor), let cursor = dataManager.metrics[.cursor] {
            snapshots.append(DashboardProviderSnapshot(title: "Cursor", service: .cursor, metrics: cursor))
        }

        return snapshots
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
        if providerVisibility.isEnabled(.claude) || providerVisibility.isEnabled(.openai) {
            labels.append("Quota APIs")
        }
        return labels
    }

    private var tightestWindowColor: Color {
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return .secondary
        }
        return MeterBarTheme.quotaStatusColor(percentLeft: limit.percentLeft)
    }

    private var overviewStatusTitle: String {
        guard !providerSnapshots.isEmpty else { return "No sources enabled" }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Waiting for usage"
        }
        if limit.percentLeft <= 0 { return "Quota exhausted" }
        if limit.percentLeft <= 10 { return "Quota needs attention" }
        if limit.percentLeft <= 25 { return "Quota is tight" }
        return "All tracked quotas look healthy"
    }

    private var overviewStatusDetail: String {
        guard !providerSnapshots.isEmpty else {
            return "Enable providers in Settings to show quota status."
        }
        guard let limit = providerSnapshots.flatMap(\.limits).min(by: { $0.percentLeft < $1.percentLeft }) else {
            return "Refresh to load enabled provider status."
        }
        if limit.percentLeft <= 0 {
            return "\(limit.title) is out until reset. Tracking \(providerSnapshots.count) local provider sources."
        }
        return "\(limit.title) has \(limit.percentLeft)% left. Tracking \(providerSnapshots.count) local provider sources."
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

    private var isRefreshButtonDisabled: Bool {
        switch activeSection {
        case .costs:
            return costTracker.isScanning
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

    private func color(for service: ServiceType) -> Color {
        MeterBarTheme.accent(for: service)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct DashboardProviderSnapshot: Identifiable {
    let id: String
    let title: String
    let service: ServiceType
    let logoKind: ProviderLogoKind
    let lastUpdated: Date
    let limits: [DashboardLimit]

    init(title: String, service: ServiceType, metrics: UsageMetrics) {
        self.id = "\(service.rawValue)-\(title)"
        self.title = title
        self.service = service
        self.logoKind = Self.logoKind(for: service)
        self.lastUpdated = metrics.lastUpdated
        self.limits = [
            DashboardLimit(title: "Session", limit: metrics.sessionLimit),
            DashboardLimit(title: "Weekly", limit: metrics.weeklyLimit),
            DashboardLimit(title: service == .codexCli ? "Code Review" : "Sonnet", limit: metrics.codeReviewLimit)
        ].compactMap { $0 }
    }

    private static func logoKind(for service: ServiceType) -> ProviderLogoKind {
        switch service {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
    }
}

private struct DashboardLimit: Identifiable {
    let id = UUID()
    let title: String
    let usageLimit: UsageLimit

    init?(title: String, limit: UsageLimit?) {
        guard let limit else { return nil }
        self.title = title
        self.usageLimit = limit
    }

    var usedPercent: Double {
        usageLimit.rawPercentage
    }

    var percentLeft: Int {
        let remainingPercent = max(0, 100 - usedPercent)
        return remainingPercent == 0 ? 0 : max(1, Int(ceil(remainingPercent)))
    }
}

private let overviewTileMinHeight: CGFloat = 220

private struct DashboardStatusHero: View {
    let title: String
    let detail: String
    let color: Color

    private var iconName: String {
        if title.localizedCaseInsensitiveContains("exhausted") {
            return "exclamationmark.octagon.fill"
        }
        if title.localizedCaseInsensitiveContains("attention")
            || title.localizedCaseInsensitiveContains("tight") {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.shield.fill"
    }

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
    let snapshot: DashboardProviderSnapshot

    private var accentColor: Color {
        MeterBarTheme.accent(for: snapshot.service)
    }

    private var primaryLimit: DashboardLimit? {
        snapshot.limits.min { $0.percentLeft < $1.percentLeft }
    }

    private var statusText: String {
        guard let primaryLimit else { return "No data" }
        if primaryLimit.percentLeft <= 0 { return "Out" }
        if primaryLimit.percentLeft <= 10 { return "Critical" }
        if primaryLimit.percentLeft <= 25 { return "Tight" }
        return "Healthy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("Updated \(relativeDate(snapshot.lastUpdated))")
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
                        DashboardLimitRow(limit: limit, accentColor: accentColor)
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

    private var statusColor: Color {
        guard let primaryLimit else { return .secondary }
        return MeterBarTheme.quotaStatusColor(percentLeft: primaryLimit.percentLeft)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CostOverviewStatusCard: View {
    let summary: CostSummary?
    let isScanning: Bool
    let formattedTokens: String

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
                    Text(isScanning ? "Scanning local logs" : "Last 30 days")
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
    let snapshot: DashboardProviderSnapshot
    let accentColor: Color
    let updatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderTitle(
                    title: snapshot.title,
                    logoKind: snapshot.logoKind,
                    color: accentColor,
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
                    DashboardLimitRow(limit: limit, accentColor: accentColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
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
    let limit: DashboardLimit
    let accentColor: Color

    private var paceContext: PaceLabelContext {
        limit.title.localizedCaseInsensitiveContains("weekly") ? .weekly : .session
    }

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
                paceContext: paceContext
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                let sweepX = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8) * (proxy.size.width + sweepWidth) - sweepWidth

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
    var daysToShow: Int = 30

    private let barSpacing: CGFloat = 4
    private let labelHeight: CGFloat = 22
    private let legendHeight: CGFloat = 18

    private var days: [DailyUsageDay] {
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

    private var providerOrder: [ServiceType] {
        [.claudeCode, .codexCli, .cursor, .claude, .openai]
    }

    private var visibleProviders: [ServiceType] {
        providerOrder.filter { provider in
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
            fullDateLabel(day.date),
            "\(formatTokens(day.totalTokens)) tokens",
            String(format: "$%.2f", day.cost)
        ]

        if day.segments.isEmpty {
            lines.append("No tracked provider usage")
        } else {
            lines.append("")
            for segment in day.segments {
                lines.append("\(segment.provider.displayName): \(formatTokens(segment.tokens)) · \(String(format: "$%.2f", segment.cost))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func color(for provider: ServiceType) -> Color {
        MeterBarTheme.accent(for: provider)
    }

    private func fullDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
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
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private var fullDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
                    DailyUsageDetailRow(day: day)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dateLabel(day.date))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(UsageFormat.tokens(day.totalTokens))
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(UsageFormat.cost(day.estimatedCostUSD))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(day.providers) { provider in
                HStack(spacing: 10) {
                    ProviderLogoView(
                        kind: logoKind(for: provider.provider),
                        size: 14,
                        foregroundColor: color(for: provider.provider)
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
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}

private struct ProviderCostBreakdown: View {
    let cost: TokenCost

    private var logoKind: ProviderLogoKind {
        switch cost.provider {
        case .codexCli, .openai:
            return .codex
        case .claude, .claudeCode:
            return .claude
        case .cursor:
            return .cursor
        }
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

            HStack(spacing: 14) {
                CostMetric(label: "Tokens", value: cost.formattedTokens)
                CostMetric(label: "Input", value: compact(cost.inputTokens))
                CostMetric(label: "Output", value: compact(cost.outputTokens))
                CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
            }

            if !cost.modelBreakdowns.isEmpty {
                CostBreakdownSection(title: "Models", items: cost.modelBreakdowns.prefix(6).map { $0 })
            }

            if !cost.originBreakdowns.isEmpty {
                CostBreakdownSection(title: "Usage Origin", items: cost.originBreakdowns.prefix(6).map { $0 })
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
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

private enum UsageFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private func logoKind(for provider: ServiceType) -> ProviderLogoKind {
    switch provider {
    case .codexCli, .openai:
        return .codex
    case .claude, .claudeCode:
        return .claude
    case .cursor:
        return .cursor
    }
}

private func color(for provider: ServiceType) -> Color {
    MeterBarTheme.accent(for: provider)
}

private extension View {
    /// A content surface for dashboard cards. Opaque system control background
    /// (not a material) on the window's content layer, with concentric corners.
    func dashboardCardBackground() -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
