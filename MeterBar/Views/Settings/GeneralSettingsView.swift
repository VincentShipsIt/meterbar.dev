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
            refreshSection
            menuBarDisplaySection
            menuBarAccountsSection
            notificationsSection
            QuotaEventSettingsView()
            generalSection
        }
    }

    // MARK: Private

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var grokAccountStore = GrokAccountStore.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared
    @StateObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
    @StateObject private var menuBarAccountSelection = MenuBarAccountSelectionStore.shared
    @StateObject private var notificationPreferences = NotificationPreferencesStore.shared
    @StateObject private var launchAtLogin = LaunchAtLoginStore.shared
    @StateObject private var softwareUpdates = SoftwareUpdateController.shared

    /// Explains a rejected menu-bar account selection; nil while under the cap.
    @State private var capNotice: String?

    /// Every tracked Claude/Codex account, already sanitized for display.
    private var menuBarAccounts: [MenuBarAccountIdentity] {
        MenuBarAccountCatalog.identities(
            claudeAccounts: claudeAccountStore.accounts,
            codexAccounts: codexAccountStore.accounts,
            grokAccounts: grokAccountStore.accounts,
            enabledServices: providerVisibility.enabledServices
        )
    }

    // The menu-bar "shows" picker enumerates pin options derived from the live
    // provider snapshots, so this tab builds the same snapshot set the Providers
    // tab does.
    private var providerSnapshots: [ProviderSnapshot] {
        ProviderSnapshotBuilder.snapshots(
            ProviderSnapshotBuilder.Input(
                metrics: dataManager.metrics,
                codexAccounts: codexAccountStore.accounts,
                codexAccountMetrics: dataManager.codexAccountMetrics,
                codexAccountAccess: codexCliService.accountAccess,
                grokAccounts: grokAccountStore.accounts,
                grokAccountMetrics: dataManager.grokAccountMetrics,
                claudeAccounts: claudeAccountStore.accounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                enabledServices: providerVisibility.enabledServices,
                claudeAccountStates: dataManager.claudeCodeAccountStates,
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

    /// Same predicate the presenter uses to decide whether a rotation timer may
    /// exist, so the controls can never claim rotation is running when it isn't.
    private var canRotateProviders: Bool {
        guard !menuBarDisplayPreferences.followsFocusedApp else { return false }
        return MenuBarRotationSequencer.rotates(
            mode: menuBarDisplayPreferences.presentationMode,
            isEnabled: true,
            pinnedKey: menuBarDisplayPreferences.pinnedCandidateKey
        )
    }

    /// Explains a disabled rotation toggle, naming the setting that is standing
    /// in its way — a pin and rotation are two answers to the same question.
    private var rotationExclusionNotice: String? {
        guard !canRotateProviders else { return nil }
        guard menuBarDisplayPreferences.presentationMode == .merged else {
            return "Rotation applies to the single menu bar item only."
        }
        if menuBarDisplayPreferences.followsFocusedApp {
            return "Focus following and rotation are mutually exclusive. Turn off focus following to rotate."
        }
        return "Pinning and rotation are mutually exclusive. Set “Menu bar shows” back to Auto to rotate."
    }

    private var refreshSection: some View {
        SettingsPanelSection(title: "Refresh", systemImage: "arrow.clockwise", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Auto-refresh interval",
                detail: "Adaptive stays between 1 and 30 minutes using only recent MeterBar interaction, "
                    + "quota movement, battery/Low Power Mode, and thermal state."
            ) {
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
                .fixedSize()
            }

            SettingsRowView(title: "Manual refresh") {
                Button {
                    Task {
                        await dataManager.refreshForExplicitAction(.manualRefresh)
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
                title: "Menu bar layout",
                detail: "Single Item keeps today’s behavior. "
                    + "One Per Provider gives every tracked provider its own item. "
                    + "One Per Account gives each selected account its own item "
                    + "(up to \(menuBarAccountSelection.itemLimit)). "
                    + "One Account With Switcher shows a single item you can repoint from its right-click menu."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.presentationMode },
                    set: { (mode: MenuBarPresentationMode) in
                        menuBarDisplayPreferences.setPresentationMode(mode)
                        capNotice = nil
                    }
                )) {
                    ForEach(MenuBarPresentationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            SettingsRowView(
                title: "Menu bar shows",
                detail: "Auto follows recent activity. Pinning keeps one provider, account, and quota "
                    + "window visible, and turns off focus following and rotation."
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
                .fixedSize()
                // One-per-provider already shows every account, so there is
                // nothing left for a pin to choose between.
                .disabled(menuBarDisplayPreferences.presentationMode == .perProvider)
            }

            followFocusedAppRows

            SettingsRowView(
                title: "Rotate providers",
                detail: "Cycle the single item through providers that have data. "
                    + "Rotation pauses while the popover is open, and a critical quota keeps the item "
                    + "until it recovers."
            ) {
                Toggle("", isOn: Binding(
                    get: { menuBarDisplayPreferences.rotatesProviders },
                    set: { menuBarDisplayPreferences.setRotatesProviders($0) }
                ))
                .labelsHidden()
                .meterBarSwitch()
                .disabled(!canRotateProviders)
            }

            if let notice = rotationExclusionNotice {
                SettingsNotice(text: notice, color: .secondary)
            }

            SettingsRowView(
                title: "Rotation interval",
                detail: "How long each provider keeps the item."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.rotationInterval },
                    set: { menuBarDisplayPreferences.setRotationInterval($0) }
                )) {
                    ForEach(StatusItemRotationInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!canRotateProviders || !menuBarDisplayPreferences.rotatesProviders)
            }

            SettingsRowView(
                title: "Label metric",
                detail: "Pace shows reserve or deficit. Icon Only keeps the status item minimal."
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
                .fixedSize()
            }

            SettingsRowView(
                title: "Quota windows",
                detail: "Session + Weekly uses bounded S/W labels in one item; unavailable values stay visible as —."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.windowMode },
                    set: { menuBarDisplayPreferences.setWindowMode($0) }
                )) {
                    ForEach(StatusItemWindowMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(menuBarDisplayPreferences.labelMetric == .iconOnly)
            }

            SettingsRowView(
                title: "Label width",
                detail: "Regular adds descriptive words; Compact uses bounded abbreviations."
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
                title: "Label font size",
                detail: "Changes only MeterBar’s status-item text; Default preserves the native menu-bar font."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.fontSize },
                    set: { menuBarDisplayPreferences.setFontSize($0) }
                )) {
                    ForEach(StatusItemFontSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(menuBarDisplayPreferences.labelMetric == .iconOnly)
            }

            SettingsRowView(
                title: "Exhausted reset countdown",
                detail: "Replace an exhausted value with its bounded reset countdown when the provider reports one."
            ) {
                Toggle("", isOn: Binding(
                    get: { menuBarDisplayPreferences.showsExhaustedResetCountdown },
                    set: { menuBarDisplayPreferences.setShowsExhaustedResetCountdown($0) }
                ))
                .labelsHidden()
                .meterBarSwitch()
                .disabled(menuBarDisplayPreferences.labelMetric == .iconOnly)
            }

            SettingsRowView(
                title: "High contrast",
                detail: "Use bold black or white text and icon tint for maximum light/dark menu-bar contrast."
            ) {
                Toggle("", isOn: Binding(
                    get: { menuBarDisplayPreferences.highContrast },
                    set: { menuBarDisplayPreferences.setHighContrast($0) }
                ))
                .labelsHidden()
                .meterBarSwitch()
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

            SettingsRowView(
                title: "What to use next",
                detail: "Show the top provider by remaining headroom at the top of the popover. "
                    + "The full ranking stays in the dashboard’s Optimize tab."
            ) {
                Toggle("", isOn: Binding(
                    get: { menuBarDisplayPreferences.showsRecommendationHint },
                    set: { menuBarDisplayPreferences.setShowsRecommendationHint($0) }
                ))
                .labelsHidden()
                .meterBarSwitch()
            }
        }
    }

    /// Opt-in merged-mode focus following and its per-app mapping (issue #341).
    ///
    /// Off by default, and mutually exclusive with pinning and rotation. The
    /// privacy posture is stated in the row copy because it is the whole reason
    /// this can be a plain toggle rather than a permission prompt.
    @ViewBuilder private var followFocusedAppRows: some View {
        SettingsRowView(
            title: "Follow focused app",
            detail: "Show the provider mapped to whichever app you are working in. "
                + "MeterBar reads only the frontmost app’s bundle identifier — no accessibility "
                + "permission is requested, and no window titles or contents are read. "
                + "Turning this on clears the pin and rotation; either one turns focus following off."
        ) {
            Toggle("", isOn: Binding(
                get: { menuBarDisplayPreferences.followsFocusedApp },
                set: { menuBarDisplayPreferences.setFollowsFocusedApp($0) }
            ))
            .labelsHidden()
            .meterBarSwitch()
            // Focus following only decides the single merged item; the other
            // layouts already show every provider or account.
            .disabled(
                menuBarDisplayPreferences.presentationMode != .merged
                    || menuBarDisplayPreferences.rotatesProviders
            )
        }

        if menuBarDisplayPreferences.presentationMode != .merged {
            SettingsNotice(
                text: "Switch the menu bar layout to Single Item to follow the focused app.",
                color: .secondary
            )
        } else if menuBarDisplayPreferences.rotatesProviders {
            SettingsNotice(
                text: "Focus following and rotation are mutually exclusive. "
                    + "Turn off rotation to follow the focused app.",
                color: .secondary
            )
        } else if menuBarDisplayPreferences.followsFocusedApp {
            if focusMappableServices.isEmpty {
                SettingsNotice(text: "No tracked providers to map yet.", color: .secondary)
            } else {
                SettingsNotice(
                    text: "Unmapped apps keep Auto. A provider that is hidden, has no data, "
                        + "or is out of quota is treated as unmapped, and a critical or exhausted "
                        + "quota anywhere still takes over the menu bar.",
                    color: .secondary
                )
                focusMappingRows
            }
        }
    }

    private var focusMappingRows: some View {
        ForEach(MenuBarFocusAppCatalog.rows(for: menuBarDisplayPreferences.focusAppMapping)) { app in
            SettingsRowView(
                title: app.displayName,
                detail: focusMappingDetail(for: app)
            ) {
                Picker("", selection: Binding(
                    get: { menuBarDisplayPreferences.focusAppMapping[app.bundleID] },
                    set: { menuBarDisplayPreferences.setFocusMapping($0, forBundleID: app.bundleID) }
                )) {
                    Text("None").tag(ServiceType?.none)
                    ForEach(focusMappableServices) { service in
                        Text(service.displayName).tag(ServiceType?.some(service))
                    }
                    // A mapping to a provider the user has since hidden stays
                    // selectable so it can be changed rather than stranded.
                    if let mapped = menuBarDisplayPreferences.focusAppMapping[app.bundleID],
                       !focusMappableServices.contains(mapped) {
                        Text("\(mapped.displayName) — hidden").tag(ServiceType?.some(mapped))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    /// Providers a mapping can point at: the tracked ones, in their usual order.
    private var focusMappableServices: [ServiceType] {
        ServiceType.allCases.filter { providerVisibility.isEnabled($0) }
    }

    private func focusMappingDetail(for app: MenuBarFocusApp) -> String? {
        guard MenuBarFocusAppCatalog.terminalBundleIDs.contains(app.bundleID) else { return nil }
        // Deliberately unmapped by default: MeterBar never inspects what runs
        // inside a terminal, so only the user knows which CLI this one means.
        return "MeterBar does not detect which CLI runs in a terminal — pick the one you use here."
    }

    /// Which Claude/Codex accounts own a menu-bar status item (issue #266).
    /// Only these two providers support multiple accounts; the others are always
    /// served by the single aggregate item.
    private var menuBarAccountsSection: some View {
        SettingsPanelSection(
            title: "Menu Bar Accounts",
            systemImage: "person.2",
            color: MeterBarTheme.appAccent
        ) {
            switch menuBarDisplayPreferences.presentationMode {
            case .merged, .perProvider:
                SettingsNotice(
                    text: "Switch the menu bar layout to One Per Account or "
                        + "One Account With Switcher to scope items to an account.",
                    color: .secondary
                )
            case .perAccount:
                perAccountSelectionRows
            case .accountSwitcher:
                switcherAccountRow
            }
        }
    }

    @ViewBuilder private var perAccountSelectionRows: some View {
        if menuBarAccounts.isEmpty {
            SettingsNotice(text: "No tracked accounts yet.", color: .secondary)
        } else {
            ForEach(menuBarAccounts) { account in
                SettingsRowView(
                    title: "\(account.badge) · \(account.displayName)",
                    detail: account.isEnabled
                        ? account.service.displayName
                        : "\(account.service.displayName) — not tracked, so it claims no status item."
                ) {
                    Toggle("", isOn: Binding(
                        get: { menuBarAccountSelection.isSelected(account.key) },
                        set: { isOn in
                            switch menuBarAccountSelection.setSelected(isOn, for: account.key) {
                            case .rejectedLimit(let limit):
                                capNotice = "The menu bar holds at most \(limit) account items. "
                                    + "Turn one off before adding another."
                            case .updated, .unchanged:
                                capNotice = nil
                            }
                        }
                    ))
                    .labelsHidden()
                    .meterBarSwitch()
                    // A disabled account can still be turned *off*: it may have
                    // been selected while enabled, and locking the toggle would
                    // strand it holding one of the four slots forever.
                    .disabled(!account.isEnabled && !menuBarAccountSelection.isSelected(account.key))
                }
            }

            if let capNotice {
                SettingsNotice(text: capNotice, color: MeterBarTheme.warning)
            }
        }
    }

    @ViewBuilder private var switcherAccountRow: some View {
        if menuBarAccounts.contains(where: \.isEnabled) {
            SettingsRowView(
                title: "Shown account",
                detail: "Switchable at any time from the status item’s right-click menu."
            ) {
                Picker("", selection: Binding(
                    get: { menuBarAccountSelection.mergedAccountKey },
                    set: { menuBarAccountSelection.setMergedAccountKey($0) }
                )) {
                    Text("First Available").tag(nil as String?)
                    ForEach(menuBarAccounts.filter(\.isEnabled)) { account in
                        Text(account.displayName).tag(account.key as String?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        } else {
            SettingsNotice(
                text: "No tracked accounts yet — the menu bar keeps its single combined item.",
                color: .secondary
            )
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
                .meterBarSwitch()
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
                    .fixedSize()
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
                    .fixedSize()
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
                .meterBarSwitch()
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
                .meterBarSwitch()
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
                .fixedSize()
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
                .meterBarSwitch()
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
}
