import MeterBarShared
import SwiftUI

// The dashboard shell: window chrome, sidebar, toolbar, and the shared data the
// pages are fed. Each page lives in its own `Dashboard*Section` file (C1 split);
// the navigation types live in `DashboardNavigation.swift`.

struct UsageDashboardView: View {
    private static let detailHorizontalPadding = MeterBarTheme.Spacing.xxl

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var grokAccountStore = GrokAccountStore.shared
    @StateObject private var openRouterAccountStore = OpenRouterAccountStore.shared
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
    @StateObject private var parseHealthStore = ProviderParseHealthStore.shared
    @StateObject private var iCloudSettings = ICloudUsageSettingsStore.shared
    @StateObject private var iCloudAggregation = ICloudUsageAggregationService.shared

    /// Owned by the shell rather than the Share page because the toolbar's
    /// Refresh also re-stamps the card.
    @State private var socialCardGeneratedAt = Date()
    /// Also shell-owned. The page views are `switch` branches, so SwiftUI tears
    /// their subtree down — and with it any page-local `@State` — the moment the
    /// user navigates to another section. Keeping these here is what the pages
    /// had before the split: the diagnostics sweep survives a round trip instead
    /// of re-running its keychain / file / SQLite I/O from an empty checklist,
    /// and the share toast doesn't silently vanish on tab switch.
    @State private var readinessReports: [ProviderReadiness] = []
    @State private var isRunningDiagnostics = false
    @State private var shareStatus: String?
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

    var body: some View {
        dashboardSplitView
        .task {
            await refreshCostsIfMissingDays()
            await syncICloudUsage()
        }
        .onChange(of: navigation.selectedSection) {
            Task { await refreshCostsIfMissingDays() }
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
                        .tag(SettingsSidebarItem.section(section))
                }
            } header: {
                Text("Settings")
            }

            Section {
                ForEach(trackedProviders, id: \.self) { service in
                    settingsProviderRow(service)
                        .tag(SettingsSidebarItem.provider(service))
                }

                Label("All Providers", systemImage: SettingsSidebarModel.catalogPage.iconName)
                    .tag(SettingsSidebarItem.section(SettingsSidebarModel.catalogPage))
            } header: {
                Text("Providers")
            }
        }
        .listStyle(.sidebar)
        .tint(MeterBarTheme.sidebarMenuTint)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        .onChange(of: providerVisibility.enabledServices) { _, enabled in
            navigation.settingsProvidersChanged(enabledServices: enabled)
        }
    }

    /// A provider row: logo, name, and a health dot on the trailing edge. The
    /// dot reads the same facts the provider's own page shows, so the sidebar
    /// and the Status row can never disagree.
    private func settingsProviderRow(_ service: ServiceType) -> some View {
        let facts = ProviderSettingsFacts.live(for: service, snapshots: providerSnapshots)
        return HStack(spacing: 6) {
            Label {
                Text(service.displayName)
            } icon: {
                ProviderLogoView(
                    kind: .forService(service),
                    size: 14,
                    foregroundColor: MeterBarTheme.accent(for: service)
                )
            }

            Spacer(minLength: 4)

            Circle()
                .fill(facts.statusColor)
                .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.displayName), \(facts.statusText)")
    }

    /// Provider rows for the sidebar — only the tracked ones. Untracked
    /// providers stay reachable from the All Providers row below them.
    private var trackedProviders: [ServiceType] {
        SettingsSidebarModel.trackedProviders(enabledServices: providerVisibility.enabledServices)
    }

    /// Settings pages available right now: Automation only when Session Wake is
    /// enabled, and Providers excluded because it is surfaced as the
    /// "All Providers" row under the provider list instead.
    private var availableSettingsSections: [SettingsSection] {
        let appPages = Set(SettingsSidebarModel.appPages)
        return SettingsSection.available(sessionWakeEnabled: sessionWakeStore.featureEnabled)
            .filter(appPages.contains)
    }

    private var settingsSelection: Binding<SettingsSidebarItem?> {
        Binding(
            get: { navigation.settingsSidebarItem },
            set: { item in
                guard let item else { return }
                navigation.selectSettingsItem(item)
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if navigation.isShowingSettings {
                            settingsSectionContent
                        } else {
                            monitoringSectionContent(
                                viewportWidth: viewport.size.width,
                                scrollProxy: proxy
                            )
                        }
                    }
                    .padding(.horizontal, Self.detailHorizontalPadding)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func monitoringSectionContent(
        viewportWidth: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        switch activeSection {
        case .overview:
            DashboardOverviewSection(
                snapshots: providerSnapshots,
                tightestLimit: tightestLimit,
                costSummary: visibleCostSummary,
                onSelectProvider: { providerID in
                    navigation.navigate(to: .limits, focusedProviderID: providerID)
                }
            )
        case .limits:
            DashboardLimitsSection(
                snapshots: providerSnapshots,
                focusedProviderID: navigation.focusedProviderID,
                scrollProxy: scrollProxy
            )
        case .status:
            DashboardStatusSection()
        case .costs:
            DashboardCostsSection(
                summary: visibleCostSummary,
                quotaSnapshot: providerSnapshot(for:)
            )
        case .optimize:
            // Unfiltered on purpose: the recommendation card lists the enabled
            // providers with no cached usage under its own "no data" state, so
            // filtering them out here would hide them instead.
            OptimizeInsightsView(providerSnapshots: allProviderSnapshots)
        case .diagnostics:
            DashboardDiagnosticsSection(
                reports: $readinessReports,
                isRunning: $isRunningDiagnostics
            )
        case .share:
            DashboardShareSection(
                costSummary: visibleCostSummary,
                providerTitles: providerSnapshots.map(\.title),
                viewportWidth: viewportWidth,
                horizontalInsets: Self.detailHorizontalPadding * 2,
                generatedAt: $socialCardGeneratedAt,
                shareStatus: $shareStatus
            )
        }
    }

    /// The selected settings page, rendered inline as dashboard content. Reuses
    /// the exact section views the old macOS Settings window hosted; the shell's
    /// ScrollView + padding wrap them, so nothing double-scrolls.
    @ViewBuilder private var settingsSectionContent: some View {
        if let service = navigation.selectedSettingsProvider {
            ProviderSettingsView(service: service)
        } else {
            settingsPageContent
        }
    }

    @ViewBuilder private var settingsPageContent: some View {
        switch navigation.selectedSettingsSection {
        case .general:
            GeneralSettingsView()
        case .providers:
            ProviderCatalogSettingsView()
        case .widget:
            WidgetSettingsView()
        case .apiUsage:
            ApiUsageSettingsView()
        case .cost:
            CostSettingsView()
        case .iCloud:
            ICloudUsageSettingsView()
        case .automation:
            SessionWakeSettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private var providerSnapshots: [ProviderSnapshot] {
        // Same builder the popover uses; most dashboard sections only render
        // providers that have reported metrics.
        allProviderSnapshots.filter(\.hasMetrics)
    }

    /// Every enabled provider/account, including the ones with no cached usage.
    /// Sections that must *name* a silent provider — the Optimize page's
    /// recommendation card — read this instead of the filtered list.
    private var allProviderSnapshots: [ProviderSnapshot] {
        ProviderSnapshotBuilder.snapshots(.live(
            stores: .init(
                dataManager: dataManager,
                claudeAccounts: claudeAccountStore.accounts,
                codexAccounts: codexAccountStore.accounts,
                grokAccounts: grokAccountStore.accounts,
                openRouterAccounts: openRouterAccountStore.accounts,
                enabledServices: providerVisibility.enabledServices,
                claudeCodeService: claudeCodeService,
                codexCliService: codexCliService,
                cursorService: cursorService,
                openRouterService: openRouterService,
                grokService: grokService
            ),
            parseHealth: parseHealthStore.records
        ))
    }

    /// The snapshot for a provider in the Costs panel — prefers an exhausted
    /// one so the cost card can surface when that provider's quota resets.
    /// Delegates to `accountSnapshot(for:)` so a shared-branding sub-pool
    /// card (Cursor's Grok Bot) can never win this selection just for being
    /// exhausted; only an actual account card can.
    private func providerSnapshot(for service: ServiceType) -> ProviderSnapshot? {
        providerSnapshots.accountSnapshot(for: service)
    }

    private var visibleCostSummary: CostSummary? {
        if iCloudSettings.isEnabled,
           iCloudSettings.showsAllMacs,
           let aggregate = iCloudAggregation.aggregate?.costSummary {
            return aggregate.filtered(to: providerVisibility.enabledServices)
        }
        return costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var tightestLimit: SnapshotLimit? {
        providerSnapshots.tightestLimit
    }

    private var isRefreshButtonDisabled: Bool {
        isRefreshButtonAnimating
    }

    private var isRefreshButtonAnimating: Bool {
        switch activeSection.refreshTarget {
        case .providerStatus:
            return providerStatusMonitor.isRefreshing
        case .costs:
            return costTracker.isRefreshInProgress
                || (activeSection.refreshesApiUsage && apiUsageStore.isLoading)
        case .usage:
            return dataManager.isLoading
        }
    }

    private func refreshDashboard() async {
        switch activeSection.refreshTarget {
        case .providerStatus:
            await providerStatusMonitor.refreshAll()
        case .costs:
            let outcome = await costTracker.scanCosts(days: 30)
            if activeSection.refreshesApiUsage,
               apiUsageStore.hasAnyAuthenticated,
               !apiUsageStore.isLoading {
                await apiUsageStore.refresh()
            }
            // Opening Share starts the background backfill, which makes the
            // refresh that follows it return without reading anything. Restamp
            // the card only when a scan actually finished, so the timestamp on
            // the artwork means what it says.
            if outcome.isAuthoritative {
                socialCardGeneratedAt = Date()
            }
        case .usage:
            await dataManager.refreshForExplicitAction(.manualRefresh)
        }
        await syncICloudUsage()
    }

    private func refreshCostsIfMissingDays() async {
        guard activeSection.refreshTarget == .costs else { return }
        await costTracker.refreshMissingDaysInBackground(days: 30)
    }

    private func syncICloudUsage() async {
        await iCloudAggregation.sync(
            localSummary: costTracker.costSummary,
            quotaSnapshots: []
        )
    }
}
