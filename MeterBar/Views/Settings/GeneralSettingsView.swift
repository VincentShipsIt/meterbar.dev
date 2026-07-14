import MeterBarShared
import SwiftUI

/// The "General" settings tab: tracked-provider toggles, refresh cadence,
/// menu-bar/popover display options, notification thresholds, and app-level
/// (login/dock/update) options. Extracted from the SettingsView monolith; each
/// store is the same shared singleton the monolith observed.
struct GeneralSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            trackedProvidersSection
            refreshSection
            menuBarDisplaySection
            notificationsSection
            generalSection
        }
    }

    // MARK: Private

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared
    @StateObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
    @StateObject private var notificationPreferences = NotificationPreferencesStore.shared
    @StateObject private var launchAtLogin = LaunchAtLoginStore.shared
    @StateObject private var softwareUpdates = SoftwareUpdateController.shared

    // The menu-bar "shows" picker enumerates pin options derived from the live
    // provider snapshots, so this tab builds the same snapshot set the Providers
    // tab does.
    private var providerSnapshots: [ProviderSnapshot] {
        ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
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
            )
        )
    }

    private var statusItemPinOptions: [StatusItemPinOption] {
        providerSnapshots.statusItemPinOptions
    }

    private var trackedProvidersSection: some View {
        SettingsPanelSection(title: "Tracked Providers", systemImage: "switch.2", color: MeterBarTheme.appAccent) {
            providerToggleRow(
                title: "Claude Code",
                detail: "Track Pro/Max quota via Claude CLI profiles.",
                service: .claudeCode
            )
            providerToggleRow(
                title: "OpenAI Codex",
                detail: "Track Codex CLI quota from local Codex auth.",
                service: .codexCli
            )
            providerToggleRow(
                title: "Cursor",
                detail: "Track Cursor quota from local Cursor state.",
                service: .cursor
            )
            providerToggleRow(
                title: "OpenRouter",
                detail: "Track credit balance, spend, and per-key limits.",
                service: .openRouter
            )
            providerToggleRow(
                title: "Grok",
                detail: "Track Grok Build weekly quota from its cached CLI login.",
                service: .grok
            )
        }
    }

    private var refreshSection: some View {
        SettingsPanelSection(title: "Refresh", systemImage: "arrow.clockwise", color: MeterBarTheme.appAccent) {
            SettingsRowView(title: "Auto-refresh interval") {
                Picker("", selection: Binding(
                    get: { dataManager.refreshInterval },
                    set: { dataManager.refreshInterval = $0 }
                )) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            SettingsRowView(title: "Manual refresh") {
                Button {
                    Task {
                        await dataManager.refreshAll()
                    }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .help("Refresh now")
            }
        }
    }

    private var menuBarDisplaySection: some View {
        SettingsPanelSection(
            title: "Menu Bar & Popover",
            systemImage: "menubar.rectangle",
            color: MeterBarTheme.appAccent
        ) {
            SettingsRowView(
                title: "Menu bar shows",
                detail: "Auto follows recent activity. Pinning keeps one provider, account, and quota window visible."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.pinnedCandidateKey },
                    set: { menuBarDisplayPreferences.setPinnedCandidateKey($0) }
                )) {
                    Text("Auto").tag(String?.none)
                    ForEach(statusItemPinOptions) { option in
                        Text(option.title).tag(String?.some(option.id))
                    }
                    if let pinned = menuBarDisplayPreferences.pinnedCandidateKey,
                       !statusItemPinOptions.contains(where: { $0.id == pinned }) {
                        Text("Pinned metric unavailable").tag(String?.some(pinned))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 240)
            }

            SettingsRowView(
                title: "Label metric",
                detail: "Icon Only keeps the status item minimal while preserving details in its tooltip."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.labelMetric },
                    set: { menuBarDisplayPreferences.setLabelMetric($0) }
                )) {
                    ForEach(StatusItemLabelMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            SettingsRowView(
                title: "Label width",
                detail: "Regular adds “left” or “used”; Compact keeps today’s number-only label."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.labelSize },
                    set: { menuBarDisplayPreferences.setLabelSize($0) }
                )) {
                    ForEach(StatusItemLabelSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(menuBarDisplayPreferences.labelMetric == .iconOnly)
            }

            SettingsRowView(
                title: "Reset times",
                detail: "Choose countdowns or local clock times on popover quota cards."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.resetTimeFormat },
                    set: { menuBarDisplayPreferences.setResetTimeFormat($0) }
                )) {
                    ForEach(ResetTimeFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }

    private var notificationsSection: some View {
        SettingsPanelSection(title: "Notifications", systemImage: "bell.badge", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Usage notifications",
                detail: "Notify when a tracked quota crosses a threshold. "
                    + "Disabled providers and stale data never notify."
            ) {
                Toggle("", isOn: Binding(
                    get: { notificationPreferences.isEnabled },
                    set: { notificationPreferences.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if notificationPreferences.isEnabled {
                SettingsRowView(
                    title: "Warn me",
                    detail: "First heads-up as a quota tightens."
                ) {
                    Picker("", selection: Binding(
                        get: { notificationPreferences.warningThreshold },
                        set: { notificationPreferences.setWarningThreshold($0) }
                    )) {
                        ForEach(NotificationThreshold.warningOptions) { threshold in
                            Text(threshold.displayName).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }

                SettingsRowView(
                    title: "Alert me",
                    detail: "Stronger alert as a quota runs out."
                ) {
                    Picker("", selection: Binding(
                        get: { notificationPreferences.criticalThreshold },
                        set: { notificationPreferences.setCriticalThreshold($0) }
                    )) {
                        ForEach(NotificationThreshold.criticalOptions) { threshold in
                            Text(threshold.displayName).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
            }
        }
    }

    private var generalSection: some View {
        SettingsPanelSection(title: "General", systemImage: "dock.rectangle", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Launch at Login",
                detail: launchAtLogin.detailText
            ) {
                Toggle("", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if let error = launchAtLogin.lastError {
                SettingsNotice(text: error, color: MeterBarTheme.warning)
            }

            SettingsRowView(
                title: "Show in Dock",
                detail: "Show MeterBar's icon in the Dock. MeterBar always stays in the menu bar."
            ) {
                Toggle("", isOn: Binding(
                    get: { dockVisibility.showInDock },
                    set: { dockVisibility.setShowInDock($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsDivider()

            SettingsRowView(
                title: "Update channel",
                detail: "Nightly tracks master builds for testing — expect pre-release bugs. "
                    + "Stable is the default and updates only on tagged releases."
            ) {
                Picker("", selection: Binding(
                    get: { softwareUpdates.channel },
                    set: { softwareUpdates.setChannel($0) }
                )) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 240)
                .disabled(softwareUpdates.configurationError != nil)
            }

            SettingsRowView(
                title: "Check for updates automatically",
                detail: "Allow MeterBar to check GitHub Releases for signed updates. Off until you opt in."
            ) {
                Toggle("", isOn: Binding(
                    get: { softwareUpdates.automaticallyChecksForUpdates },
                    set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(softwareUpdates.configurationError != nil)
            }

            SettingsRowView(
                title: "Software Update",
                detail: softwareUpdates.configurationError ?? "Check for a new signed MeterBar release now."
            ) {
                Button("Check Now") {
                    softwareUpdates.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!softwareUpdates.canCheckForUpdates)
            }
        }
        .onAppear {
            // The login-item status can change behind the app's back in System
            // Settings, so re-read it whenever settings is shown.
            launchAtLogin.refreshStatus()
            softwareUpdates.refreshState()
        }
    }

    private func providerToggleRow(title: String, detail: String, service: ServiceType) -> some View {
        SettingsRowView(title: title, detail: detail) {
            Toggle("", isOn: Binding(
                get: { providerVisibility.isEnabled(service) },
                set: { isEnabled in
                    providerVisibility.set(service, isEnabled: isEnabled)
                    Task {
                        await dataManager.refreshAll()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}
