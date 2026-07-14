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
            window.backgroundColor = .windowBackgroundColor
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

@MainActor
final class DashboardNavigationStore: ObservableObject {
    static let shared = DashboardNavigationStore()

    @Published var selectedSection: DashboardSection = .overview
    @Published var focusedProviderID: ProviderSnapshot.ID?

    private init() {}

    func navigate(to section: DashboardSection, focusedProviderID: ProviderSnapshot.ID? = nil) {
        selectedSection = section
        self.focusedProviderID = focusedProviderID
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

    @State private var readinessReports: [ProviderReadiness] = []
    @State private var isRunningDiagnostics = false
    @State private var socialCardGeneratedAt = Date()
    @State private var socialShareStatus: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        refreshToolbarButton
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarList: some View {
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
            .padding(.horizontal, MeterBarTheme.Spacing.xxl)
            .padding(.top, MeterBarTheme.Spacing.md)
            .padding(.bottom, MeterBarTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background {
            // Safe-area handling now lives inside MeterBarDetailBackground: the
            // material bleeds full-bleed, the accent tint stays below the bar so
            // the system scroll-edge effect is unobstructed behind toolbar items.
            MeterBarDetailBackground()
        }
        .navigationTitle("")
        .navigationSubtitle("")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    ProviderOverviewStatusCard(snapshot: snapshot) {
                        navigation.navigate(to: .limits, focusedProviderID: snapshot.id)
                    }
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
                    ProviderLimitsCard(snapshot: snapshot)
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
        DashboardCard(title: "30 Day Token Spend", trailing: costRefreshStatusText) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Local subscription logs are estimated using API token rates "
                        + "so Codex and Claude can be compared."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)

                if costTracker.isScanning {
                    costScanChart(height: 220, compact: false, showsProgressBadge: true)
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
        var count = 0
        if providerVisibility.isEnabled(.codexCli) {
            count += 1
        }
        if providerVisibility.isEnabled(.claudeCode) {
            count += claudeAccountStore.enabledAccounts.count
        }
        if providerVisibility.isEnabled(.cursor) {
            count += 1
        }
        return count
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
        .task {
            if readinessReports.isEmpty {
                await runDiagnostics()
            }
        }
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

        let enabledProviders = providerVisibility.enabledServices
        let errors = currentRefreshErrors()
        let reports = await Task.detached(priority: .userInitiated) {
            ProviderReadinessInspector.reports(
                providers: enabledProviders,
                refreshErrors: errors
            )
        }.value
        readinessReports = reports
    }

    /// Each provider's live last-refresh error, fed into the readiness core so the
    /// "Last refresh" check reflects the app's actual runtime state.
    private func currentRefreshErrors() -> [ServiceType: ServiceError] {
        var result: [ServiceType: ServiceError] = [:]
        if let error = claudeCodeService.lastError { result[.claudeCode] = error }
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
