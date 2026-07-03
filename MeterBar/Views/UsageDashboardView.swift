import AppKit
import SwiftUI
import MeterBarShared
import UniformTypeIdentifiers

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
    case optimize = "Optimize"
    case diagnostics = "Diagnostics"
    case share = "Share"
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
        case .optimize:
            return "leaf.fill"
        case .diagnostics:
            return "stethoscope"
        case .share:
            return "square.and.arrow.up.fill"
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
    @State private var readinessReports: [ProviderReadiness] = []
    @State private var isRunningDiagnostics = false
    @State private var socialCardGeneratedAt = Date()
    @State private var socialShareStatus: String?

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
            if selectedSection == .diagnostics {
                Task { await runDiagnostics() }
            }
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
                case .optimize:
                    OptimizeInsightsView()
                case .diagnostics:
                    diagnosticsContent
                case .share:
                    shareContent
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

    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SocialShareCardPreview(content: socialShareCardContent)
                .frame(maxWidth: 860)
                .accessibilityLabel("MeterBar social share card preview")

            HStack(spacing: 10) {
                Button {
                    copySocialCardImage()
                } label: {
                    Label("Copy PNG", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    saveSocialCardImage()
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    copyTweetText()
                } label: {
                    Label("Copy Text", systemImage: "text.quote")
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

            DashboardCard(title: "Tweet Text") {
                Text(socialShareCardContent.tweetText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makeSocialShareCardContent(generatedAt: Date) -> SocialShareCardContent {
        // Reuse the canonical tightest-quota window the overview already derives
        // (`providerSnapshots.tightestLimit`) instead of re-deriving it locally.
        let tightest = tightestLimit
        return SocialShareCardContent(
            tokenTotal: visibleCostSummary?.totalTokens,
            estimatedCostUSD: visibleCostSummary?.totalCostUSD,
            sourceCount: socialSourceCount,
            providerNames: socialProviderNames,
            tightestLimitTitle: tightest?.title,
            tightestPercentLeft: tightest?.percentLeft,
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

    private var socialShareCardContent: SocialShareCardContent {
        makeSocialShareCardContent(generatedAt: socialCardGeneratedAt)
    }

    private var socialSourceCount: Int {
        max(providerSnapshots.count, visibleCostSummary?.costs.count ?? 0)
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
        let ready = readinessReports.filter(\.isHealthy).count
        let attention = readinessReports.filter { $0.overall == .fail }.count
        return "\(ready) ready · \(attention) need attention"
    }

    /// Runs the readiness inspector off the main actor (it does keychain / file /
    /// SQLite I/O) and publishes the reports back on the main actor.
    private func runDiagnostics() async {
        isRunningDiagnostics = true
        let errors = currentRefreshErrors()
        let reports = await Task.detached(priority: .userInitiated) {
            ProviderReadinessInspector.reports(refreshErrors: errors)
        }.value
        readinessReports = reports
        isRunningDiagnostics = false
    }

    /// Each provider's live last-refresh error, fed into the readiness core so the
    /// "Last refresh" check reflects the app's actual runtime state.
    private func currentRefreshErrors() -> [ServiceType: ServiceError] {
        var result: [ServiceType: ServiceError] = [:]
        if let error = claudeCodeService.lastError { result[.claudeCode] = error }
        if let error = codexCliService.lastError { result[.codexCli] = error }
        if let error = cursorService.lastError { result[.cursor] = error }
        return result
    }

    private func copyDiagnosticsToClipboard() {
        let text = DiagnosticsReportText.plainText(readinessReports)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var sectionSubtitle: String {
        switch activeSection {
        case .overview:
            return "Current health and local token history"
        case .limits:
            return "Every tracked quota window"
        case .costs:
            return "Local 30-day token spend"
        case .optimize:
            return "Where tokens go and how to trim them"
        case .diagnostics:
            return "Provider setup health — safe to share"
        case .share:
            return "Social card export"
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
        case .costs, .share, .optimize:
            return costTracker.isRefreshInProgress
        case .overview, .limits, .diagnostics, .settings:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        if activeSection == .costs || activeSection == .share || activeSection == .optimize {
            await costTracker.scanCosts(days: 30)
            socialCardGeneratedAt = Date()
        } else {
            await dataManager.refreshAll()
        }
    }

    private func refreshCostsIfMissingDays() async {
        let costBackedSections: Set<DashboardSection> = [.overview, .costs, .share, .optimize]
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

    private func copyTweetText() {
        let generatedAt = Date()
        let content = makeSocialShareCardContent(generatedAt: generatedAt)
        socialCardGeneratedAt = generatedAt

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.tweetText, forType: .string)
        setSocialShareStatus("Text copied")
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
        withAnimation(.easeInOut(duration: 0.15)) {
            socialShareStatus = status
        }
    }
}
