import MeterBarShared
import SwiftUI

/// The "General" settings tab: tracked-provider toggles, refresh cadence,
/// notification thresholds, and app-level (login/dock/update) options.
/// Extracted from the SettingsView monolith; each store is the same shared
/// singleton the monolith observed.
struct GeneralSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            trackedProvidersSection
            refreshSection
            notificationsSection
            generalSection
        }
    }

    // MARK: Private

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared
    @StateObject private var notificationPreferences = NotificationPreferencesStore.shared
    @StateObject private var launchAtLogin = LaunchAtLoginStore.shared
    @StateObject private var softwareUpdates = SoftwareUpdateController.shared

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
                }
                .buttonStyle(.bordered)
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
