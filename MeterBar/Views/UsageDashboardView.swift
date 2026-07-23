import AppKit
import Combine
import SwiftUI
import MeterBarShared
import UniformTypeIdentifiers

@MainActor
private func applyWindowChrome(_ window: NSWindow, section _: DashboardSection? = nil) {
    window.title = ""
    window.subtitle = ""
    window.titleVisibility = .visible
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.toolbarStyle = .unified
}

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func show(section: DashboardSection? = nil, focusedProviderID: String? = nil) {
        if let section {
            DashboardNavigationStore.shared.navigate(to: section, focusedProviderID: focusedProviderID)
        } else if let focusedProviderID {
            DashboardNavigationStore.shared.navigate(to: .limits, focusedProviderID: focusedProviderID)
        }

        if window == nil {
            let hostingController = NSHostingController(rootView: UsageDashboardView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            applyWindowChrome(window, section: DashboardNavigationStore.shared.selectedSection)
            // Clear, not a solid fill: with a transparent titlebar over
            // fullSizeContentView, a solid windowBackgroundColor paints the
            // titlebar strip as a flat dead slab. Clearing it lets the sidebar's
            // material and the detail's MeterBarDetailBackground bleed up under
            // the bar, so the chrome reads as one continuous surface.
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window

            // Discard the window on close instead of resurrecting it forever.
            // A long-lived cached window can accumulate stale window-server
            // state (observed: a corner radius stuck at ~35pt instead of the
            // standard ~26pt after display changes during a long uptime);
            // recreating per open keeps the chrome fresh, matching the
            // lifecycle a SwiftUI Window scene gives MacSweep.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                // Delivered on the main queue; tear down synchronously so a
                // reopen between close and a deferred hop can't order-front
                // the dying window and orphan it.
                MainActor.assumeIsolated {
                    UsageDashboardWindowController.shared.windowDidClose()
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open (or front) the dashboard window in its in-window settings mode. This
    /// is what ⌘,, the app menu's "Settings…", and the popover's settings entry
    /// points now call — there is no separate Settings window.
    func showSettings(_ section: SettingsSection = .general) {
        DashboardNavigationStore.shared.openSettings(section)
        show()
    }

    private func windowDidClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }
}

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case limits = "Limits"
    case status = "Status"
    case costs = "Costs"
    case optimize = "Optimize"
    case diagnostics = "Diagnostics"
    case share = "Share"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .limits:
            return "chart.bar.fill"
        case .status:
            return "waveform.path.ecg"
        case .costs:
            return "dollarsign.circle.fill"
        case .optimize:
            return "leaf.fill"
        case .diagnostics:
            return "stethoscope"
        case .share:
            return "square.and.arrow.up.fill"
        }
    }

    /// Sidebar layout: frequency-ordered monitoring pages first, then health
    /// checks, then utilities. App settings live in the dedicated macOS
    /// Settings scene rather than masquerading as dashboard content.
    struct SidebarGroup: Identifiable {
        let title: String?
        let sections: [DashboardSection]

        var id: String { sections.first?.id ?? title ?? "" }
    }

    static let sidebarGroups: [SidebarGroup] = [
        SidebarGroup(title: nil, sections: [.overview, .limits, .costs, .optimize]),
        SidebarGroup(title: "Health", sections: [.status, .diagnostics]),
        SidebarGroup(title: "Utilities", sections: [.share]),
    ]

    var titlebarSubtitle: String {
        switch self {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .status:
            return "Provider service health"
        case .costs:
            return "Local 30-day token spend"
        case .optimize:
            return "Where tokens go and how to trim them"
        case .diagnostics:
            return "Provider setup health"
        case .share:
            return "Social card export"
        }
    }
}

/// The app-settings pages, surfaced as an in-window mode of the dashboard rather
/// than a separate macOS Settings window. Mirrors the tabs the old `SettingsView`
/// shell carried, reusing the same section views. `.automation` is feature-gated
/// and only appears when Session Wake is enabled.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case providers = "Providers"
    case widget = "Widget"
    case apiUsage = "API Usage"
    case cost = "Cost"
    case automation = "Automation"
    case about = "About"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "square.grid.2x2"
        case .widget: return "rectangle.3.group"
        case .apiUsage: return "key"
        case .cost: return "chart.bar"
        case .automation: return "moon.zzz"
        case .about: return "info.circle"
        }
    }
}

enum EnabledQuotaSourceCounter {
    static func count(
        enabledServices: Set<ServiceType>,
        codexAccountCount: Int,
        claudeAccountCount: Int
    ) -> Int {
        enabledServices.reduce(into: 0) { count, service in
            switch service {
            case .codexCli:
                count += codexAccountCount
            case .claudeCode:
                count += claudeAccountCount
            case .cursor, .openRouter, .grok:
                count += 1
            }
        }
    }
}

@MainActor
final class DashboardNavigationStore: ObservableObject {
    static let shared = DashboardNavigationStore()

    @Published var selectedSection: DashboardSection = .overview
    @Published var focusedProviderID: ProviderSnapshot.ID?

    /// When true the dashboard swaps its sidebar + content for the settings
    /// pages (the gear next to Refresh, or ⌘,/Settings…). No separate window.
    @Published var isShowingSettings = false
    @Published var selectedSettingsSection: SettingsSection = .general

    private init() {}

    func navigate(to section: DashboardSection, focusedProviderID: ProviderSnapshot.ID? = nil) {
        selectedSection = section
        self.focusedProviderID = focusedProviderID
        isShowingSettings = false
    }

    /// Enter the in-window settings mode on `section` (defaults to General).
    func openSettings(_ section: SettingsSection = .general) {
        selectedSettingsSection = section
        isShowingSettings = true
    }

    /// Return from settings to the monitoring dashboard.
    func closeSettings() {
        isShowingSettings = false
    }
}

struct UsageDashboardView: View {
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared
    @StateObject private var providerStatusMonitor = ProviderStatusMonitor.shared
    @StateObject private var navigation = DashboardNavigationStore.shared
    @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared

    @State private var readinessReports: [ProviderReadiness] = []
    @State private var isRunningDiagnostics = false
    @State private var socialCardGeneratedAt = Date()
    @State private var socialShareStatus: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var activeSection: DashboardSection { navigation.selectedSection }

    private var selectedSection: Binding<DashboardSection?> {
        Binding(
            get: { navigation.selectedSection },
            set: { section in
                guard let section else { return }
                navigation.selectedSection = section
            }
        )
    }

    private var overviewGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
            count: 2
        )
    }

    var body: some View {
        dashboardSplitView
        .background {
            MeterBarMenuWindowAccessor { window in
                guard let window else { return }
                applyWindowChrome(window, section: activeSection)
            }
        }
        .task {
            await refreshCostsIfMissingDays()
        }
        .onChange(of: navigation.selectedSection) {
            Task { await refreshCostsIfMissingDays() }
            if navigation.selectedSection == .diagnostics {
                Task { await runDiagnostics() }
            }
            if navigation.selectedSection != .limits {
                navigation.focusedProviderID = nil
            }
        }
    }

    private var dashboardSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarList
        } detail: {
            detailContent
                .toolbar { dashboardToolbar }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The primary-action toolbar. In monitoring mode: Refresh + a gear that
    /// enters settings. In settings mode: a single "Done" that returns to the
    /// dashboard (Refresh has nothing to act on there). Settings is a mode of
    /// this one window — never a separate window.
    @ToolbarContentBuilder private var dashboardToolbar: some ToolbarContent {
        if navigation.isShowingSettings {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : MeterBarTheme.Motion.standard) {
                        navigation.closeSettings()
                    }
                } label: {
                    Label("Done", systemImage: "chevron.backward")
                }
                .help("Back to dashboard")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                refreshToolbarButton
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : MeterBarTheme.Motion.standard) {
                        navigation.openSettings()
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    @ViewBuilder private var sidebarList: some View {
        if navigation.isShowingSettings {
            settingsSidebarList
        } else {
            monitoringSidebarList
        }
    }

    private var monitoringSidebarList: some View {
        List(selection: selectedSection) {
            ForEach(DashboardSection.sidebarGroups) { group in
                Section {
                    ForEach(group.sections) { section in
                        Label(section.rawValue, systemImage: section.iconName)
                            .tag(section)
                    }
                } header: {
                    if let title = group.title {
                        Text(title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(MeterBarTheme.sidebarMenuTint)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    /// Settings pages shown *in place of* the monitoring sidebar while in
    /// settings mode — the same sidebar column, different rows.
    private var settingsSidebarList: some View {
        List(selection: settingsSelection) {
            Section {
                ForEach(availableSettingsSections) { section in
                    Label(section.rawValue, systemImage: section.iconName)
                        .tag(section)
                }
            } header: {
                Text("Settings")
            }
        }
        .listStyle(.sidebar)
        .tint(MeterBarTheme.sidebarMenuTint)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    /// Settings sections available right now — Automation only when Session Wake
    /// is enabled, matching the old settings shell's feature gate.
    private var availableSettingsSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            section != .automation || sessionWakeStore.featureEnabled
        }
    }

    private var settingsSelection: Binding<SettingsSection?> {
        Binding(
            get: { navigation.selectedSettingsSection },
            set: { section in
                guard let section else { return }
                navigation.selectedSettingsSection = section
            }
        )
    }

    private var refreshToolbarButton: some View {
        Button {
            Task { await refreshDashboard() }
        } label: {
            RefreshingIcon(isRefreshing: isRefreshButtonAnimating)
        }
        .help(isRefreshButtonAnimating ? "Refreshing usage" : "Refresh usage")
        .disabled(isRefreshButtonDisabled)
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if navigation.isShowingSettings {
                    settingsSectionContent
                } else {
                    monitoringSectionContent
                }
            }
            .padding(.horizontal, MeterBarTheme.Spacing.xxl)
            .padding(.top, MeterBarTheme.Spacing.md)
            .padding(.bottom, MeterBarTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(for: .top)
        .background {
            // This is one continuous surface through the titlebar. The toolbar
            // still owns the refresh/settings controls, but paints no separate
            // background band and adds no scroll-edge fade.
            MeterBarDetailBackground()
        }
        .navigationTitle("")
        .navigationSubtitle("")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var monitoringSectionContent: some View {
        switch activeSection {
        case .overview:
            overviewContent
        case .limits:
            limitsContent
        case .status:
            statusPagesContent
        case .costs:
            costsContent
        case .optimize:
            OptimizeInsightsView()
        case .diagnostics:
            diagnosticsContent
        case .share:
            shareContent
        }
    }

    /// The selected settings page, rendered inline as dashboard content. Reuses
    /// the exact section views the old macOS Settings window hosted; the shell's
    /// ScrollView + padding wrap them, so nothing double-scrolls.
    @ViewBuilder private var settingsSectionContent: some View {
        switch navigation.selectedSettingsSection {
        case .general:
            GeneralSettingsView()
        case .providers:
            ProviderSettingsView()
        case .widget:
            WidgetSettingsView()
        case .apiUsage:
            ApiUsageSettingsView()
        case .cost:
            CostSettingsView()
        case .automation:
            SessionWakeSettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverviewSummaryStrip(
                tightestLimit: tightestLimit,
                sourceCount: providerSnapshots.count,
                enabledSourceCount: enabledQuotaSourceCount,
                estimatedCost: visibleCostSummary?.formattedTotalCost,
                formattedTokens: UsageFormat.tokens(visibleCostSummary?.totalTokens ?? 0)
            )

            LazyVGrid(columns: overviewGridColumns, alignment: .leading, spacing: 12) {
                ForEach(providerSnapshots) { snapshot in
                    // Same shared provider card as the popover and the Limits
                    // page; tapping it jumps to that provider in Limits.
                    ProviderStatusCard(
                        snapshot: snapshot,
                        onSelect: { navigation.navigate(to: .limits, focusedProviderID: snapshot.id) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var limitsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if providerSnapshots.isEmpty {
                DashboardCard(title: "No Quota Windows") {
                    Text("Enable providers in Settings to show quota windows.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(orderedProviderSnapshotsForLimits) { snapshot in
                    // The one provider card, shared with the popover, so the two
                    // surfaces are physically the same component and cannot drift.
                    ProviderStatusCard(snapshot: snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            CostOverviewStatusCard(
                summary: visibleCostSummary,
                isScanning: costTracker.isScanning,
                isRefreshingMissingDays: costTracker.isRefreshingMissingDays,
                formattedTokens: UsageFormat.tokens(visibleCostSummary?.totalTokens ?? 0)
            )

            LifetimeCostSummaryCard(
                summary: visibleCostSummary?.lifetime,
                isScanning: costTracker.isRefreshInProgress
            )

            costTrendCard

            if let summary = visibleCostSummary, !summary.dailyUsage.isEmpty {
                DashboardCard(title: "Daily Details", trailing: "Last 30 days") {
                    DailyUsageBreakdownList(dailyUsage: summary.dailyUsage)
                }
            }

            if let summary = visibleCostSummary, !summary.costs.isEmpty {
                ForEach(summary.costs) { cost in
                    ProviderCostBreakdown(
                        cost: cost,
                        quotaSnapshot: providerSnapshot(for: cost.provider)
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

    private var statusPagesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "Provider Status Pages", trailing: statusPagesSummary) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Live status from each provider's public status page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await providerStatusMonitor.refreshAll() }
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(providerStatusMonitor.isRefreshing)
                }
            }

            ProviderStatusTable(
                reports: providerStatusMonitor.reports,
                errors: providerStatusMonitor.errors,
                openStatusPage: openStatusPage
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await providerStatusMonitor.refreshAllIfNeeded()
        }
    }

    private var statusPagesSummary: String? {
        if providerStatusMonitor.isRefreshing {
            return "Refreshing..."
        }

        let issueCount = providerStatusMonitor.reports.values.filter(\.hasIssue).count
        if issueCount == 0, providerStatusMonitor.reports.count == ServiceType.allCases.count {
            return "All operational"
        }
        if issueCount == 1 {
            return "1 issue"
        }
        if issueCount > 1 {
            return "\(issueCount) issues"
        }
        return nil
    }

    private var costTrendCard: some View {
        DashboardCard(title: "30 Day Spend", trailing: costRefreshStatusText) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Local subscription logs are estimated using API token rates "
                        + "so Codex and Claude can be compared."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let summary = visibleCostSummary {
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

    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SocialShareCardPreview(content: socialShareCardContent)
                .frame(maxWidth: 860)
                .accessibilityLabel("MeterBar 30-day token receipt preview")

            HStack(spacing: 10) {
                Button {
                    copySocialCardImage()
                } label: {
                    Label("Copy PNG", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glassProminent)

                Button {
                    saveSocialCardImage()
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    copyShareCaption()
                } label: {
                    Label("Copy Caption", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)

                if visibleCostSummary?.dailyUsage.isEmpty ?? true {
                    Button {
                        Task {
                            await costTracker.scanCosts(days: 30)
                            socialCardGeneratedAt = Date()
                        }
                    } label: {
                        Label("Scan 30 Days", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(costTracker.isRefreshInProgress)
                }

                Spacer()

                if let socialShareStatus {
                    Text(socialShareStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }

            DashboardCard(title: "Share Caption") {
                Text(socialShareCardContent.shareCaption)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makeSocialShareCardContent(generatedAt: Date) -> SocialShareCardContent {
        SocialShareCardContent(
            tokenTotal: visibleCostSummary?.totalTokens,
            sessionCount: socialSessionCount,
            providerNames: socialProviderNames,
            topProviderName: socialTopProviderName,
            dailyTokenTotals: socialDailyTokenTotals(generatedAt: generatedAt),
            generatedAt: generatedAt
        )
    }

    private func socialDailyTokenTotals(generatedAt: Date) -> [Int] {
        guard let visibleCostSummary else { return [] }
        return SocialShareCardContent.dailyTokenTotals(
            from: visibleCostSummary.dailyUsage,
            now: generatedAt
        )
    }

    private var providerSnapshots: [ProviderSnapshot] {
        // Same builder the popover uses; the dashboard only renders providers
        // that have reported metrics.
        ProviderSnapshotBuilder.snapshots(ProviderSnapshotBuilder.Input(
            metrics: dataManager.metrics,
            codexAccounts: codexAccountStore.accounts,
            codexAccountMetrics: dataManager.codexAccountMetrics,
            claudeAccounts: claudeAccountStore.accounts,
            claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
            enabledServices: providerVisibility.enabledServices,
            claudeCodeHasAccess: claudeCodeService.hasAccess,
            codexCliHasAccess: codexCliService.hasAccess,
            cursorHasAccess: cursorService.hasAccess,
            openRouterHasAccess: openRouterService.hasAccess,
            grokHasAccess: grokService.hasAccess
        ))
        .filter(\.hasMetrics)
    }

    private var orderedProviderSnapshotsForLimits: [ProviderSnapshot] {
        guard let focusedProviderID = navigation.focusedProviderID else {
            return providerSnapshots
        }
        let focused = providerSnapshots.filter { $0.id == focusedProviderID }
        guard !focused.isEmpty else { return providerSnapshots }
        return focused + providerSnapshots.filter { $0.id != focusedProviderID }
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

    private var socialShareCardContent: SocialShareCardContent {
        makeSocialShareCardContent(generatedAt: socialCardGeneratedAt)
    }

    private var socialSessionCount: Int? {
        guard let costs = visibleCostSummary?.costs else { return nil }
        return costs.reduce(0) { $0 + $1.sessionCount }
    }

    private var socialTopProviderName: String? {
        visibleCostSummary?.costs.max { lhs, rhs in
            lhs.totalTokens < rhs.totalTokens
        }?.provider.displayName
    }

    private var socialProviderNames: [String] {
        if let costs = visibleCostSummary?.costs, !costs.isEmpty {
            return costs.map(\.provider.displayName)
        }

        let snapshotTitles = providerSnapshots.map(\.title)
        if !snapshotTitles.isEmpty {
            return snapshotTitles
        }

        return enabledSourceLabels
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

    private var enabledQuotaSourceCount: Int {
        EnabledQuotaSourceCounter.count(
            enabledServices: providerVisibility.enabledServices,
            codexAccountCount: codexAccountStore.enabledAccounts.count,
            claudeAccountCount: claudeAccountStore.enabledAccounts.count
        )
    }

    private var tightestLimit: SnapshotLimit? {
        providerSnapshots.tightestLimit
    }

    private var diagnosticsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardCard(title: "Provider Diagnostics", trailing: diagnosticsSummary) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These checks run locally. Every line is redacted — safe to paste into a GitHub issue.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label("Re-run checks", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRunningDiagnostics)

                        Button {
                            copyDiagnosticsToClipboard()
                        } label: {
                            Label("Copy report", systemImage: "doc.on.doc")
                        }
                        .disabled(readinessReports.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if readinessReports.isEmpty {
                DashboardCard(title: "Running checks…") {
                    Text("Gathering provider setup status.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ReadinessChecklist(reports: readinessReports)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: diagnosticsInputKey) {
            let reports = await inspectReadiness()
            guard !Task.isCancelled else { return }
            readinessReports = reports
        }
    }

    private struct DiagnosticsInputKey: Equatable {
        let providers: [ServiceType]
        let defaultClaudeAccountEnabled: Bool
        let enabledClaudeCustomAccountIDs: [UUID]
    }

    private var diagnosticsInputKey: DiagnosticsInputKey {
        DiagnosticsInputKey(
            providers: ServiceType.allCases.filter { providerVisibility.enabledServices.contains($0) },
            defaultClaudeAccountEnabled: claudeAccountStore.defaultAccountIsEnabled,
            enabledClaudeCustomAccountIDs: claudeAccountStore.enabledAccounts
                .filter { !$0.isDefault }
                .map(\.id)
        )
    }

    private var diagnosticsSummary: String? {
        guard !readinessReports.isEmpty else { return nil }
        return ProviderReadinessSummary(reports: readinessReports).displayText
    }

    /// Runs the readiness inspector off the main actor (it does keychain / file /
    /// SQLite I/O) and publishes the reports back on the main actor.
    @MainActor
    private func runDiagnostics() async {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }

        let reports = await inspectReadiness()
        guard !Task.isCancelled else { return }
        readinessReports = reports
    }

    private func inspectReadiness() async -> [ProviderReadiness] {
        let enabledProviders = providerVisibility.enabledServices
        let errors = currentRefreshErrors()
        let defaultClaudeAccountEnabled = claudeAccountStore.defaultAccountIsEnabled
        let enabledClaudeAccounts = claudeAccountStore.enabledAccounts
        let claudeMetrics = enabledClaudeAccounts.compactMap {
            dataManager.claudeCodeAccountMetrics[$0.id]
        }
        return await Task.detached(priority: .userInitiated) {
            ProviderReadinessInspector.reports(
                providers: enabledProviders,
                refreshErrors: errors,
                claudeDefaultAccountEnabled: defaultClaudeAccountEnabled,
                claudeEnabledAccountMetrics: claudeMetrics
            )
        }.value
    }

    /// Each provider's live last-refresh error, fed into the readiness core so the
    /// "Last refresh" check reflects the app's actual runtime state.
    private func currentRefreshErrors() -> [ServiceType: ServiceError] {
        var result: [ServiceType: ServiceError] = [:]
        if claudeAccountStore.defaultAccountIsEnabled,
           let error = claudeCodeService.lastError {
            result[.claudeCode] = error
        }
        if let error = codexCliService.lastError { result[.codexCli] = error }
        if let error = cursorService.lastError { result[.cursor] = error }
        if let error = openRouterService.lastError { result[.openRouter] = error }
        if let error = grokService.lastError { result[.grok] = error }
        return result
    }

    private func copyDiagnosticsToClipboard() {
        let text = DiagnosticsReportText.plainText(readinessReports)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            return costTracker.isRefreshInProgress || apiUsageStore.isLoading
        case .share, .optimize:
            return costTracker.isRefreshInProgress
        case .status:
            return providerStatusMonitor.isRefreshing
        case .overview, .limits, .diagnostics:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        if activeSection == .status {
            await providerStatusMonitor.refreshAll()
        } else if activeSection == .costs || activeSection == .share || activeSection == .optimize {
            await costTracker.scanCosts(days: 30)
            if activeSection == .costs, apiUsageStore.hasAnyAuthenticated, !apiUsageStore.isLoading {
                await apiUsageStore.refresh()
            }
            socialCardGeneratedAt = Date()
        } else {
            await dataManager.refreshAll()
        }
    }

    private func openStatusPage(for service: ServiceType) {
        guard let url = service.statusPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshCostsIfMissingDays() async {
        let costBackedSections: Set<DashboardSection> = [.costs, .share, .optimize]
        guard costBackedSections.contains(activeSection) else { return }
        await costTracker.refreshMissingDaysInBackground(days: 30)
    }

    private func copySocialCardImage() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        guard let image = renderSocialCardImage(content: content) else {
            setSocialShareStatus("PNG render failed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            setSocialShareStatus("PNG copied")
        } else {
            setSocialShareStatus("Copy failed")
        }
    }

    private func saveSocialCardImage() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        guard let pngData = renderSocialCardPNGData(content: content) else {
            setSocialShareStatus("PNG render failed")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = content.defaultFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
                setSocialShareStatus("PNG saved")
            } catch {
                setSocialShareStatus("Save failed")
            }
        }
    }

    private func copyShareCaption() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.shareCaption, forType: .string)
        setSocialShareStatus("Caption copied")
    }

    private func renderSocialCardImage(content: SocialShareCardContent) -> NSImage? {
        let exportSize = SocialShareCardLayout.exportSize
        let renderer = ImageRenderer(
            content: SocialShareCard(content: content)
                .frame(width: exportSize.width, height: exportSize.height)
        )
        renderer.proposedSize = ProposedViewSize(width: exportSize.width, height: exportSize.height)
        renderer.scale = 1
        return renderer.nsImage
    }

    private func renderSocialCardPNGData(content: SocialShareCardContent) -> Data? {
        guard
            let image = renderSocialCardImage(content: content),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private func setSocialShareStatus(_ status: String) {
        withAnimation(MeterBarTheme.Motion.standard) {
            socialShareStatus = status
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
                    tint: tightestColor,
                    style: .compact
                )
            }

            DashboardMetricTile(
                title: "30-day estimate",
                value: estimatedCost ?? "Scan needed",
                caption: "\(formattedTokens) tokens",
                systemImage: "chart.bar.xaxis",
                tint: MeterBarTheme.success,
                style: .compact
            )

            DashboardMetricTile(
                title: "Tracked sources",
                value: "\(sourceCount)",
                caption: sourceCaption,
                systemImage: "checklist.checked",
                tint: MeterBarTheme.appAccent,
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
