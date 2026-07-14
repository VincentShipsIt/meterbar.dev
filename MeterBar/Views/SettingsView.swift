import AppKit
import MeterBarShared
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    // MARK: Internal

    var body: some View {
        settingsTabView
        .alert(
            "Claude Reconnect Failed",
            isPresented: Binding(
                get: { claudeReconnectError != nil },
                set: { isPresented in
                    if !isPresented {
                        claudeReconnectError = nil
                    }
                }
            )
        ) {
            Button("OK") { claudeReconnectError = nil }
        } message: {
            Text(claudeReconnectError ?? "Could not open the Claude reconnect flow.")
        }
        .sheet(isPresented: $isAddingClaudeAccount) {
            AddClaudeAccountSheet { name, configDirectory in
                addClaudeAccount(name: name, configDirectory: configDirectory)
                isAddingClaudeAccount = false
            }
        }
        .sheet(isPresented: $isAddingCodexAccount) {
            AddCodexAccountSheet { name, homeDirectory in
                codexAccountStore.addAccount(name: name, homeDirectory: homeDirectory)
                isAddingCodexAccount = false
                Task { await dataManager.refreshAll() }
            }
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
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared
    @StateObject private var notificationPreferences = NotificationPreferencesStore.shared
    @StateObject private var launchAtLogin = LaunchAtLoginStore.shared
    @StateObject private var softwareUpdates = SoftwareUpdateController.shared
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared
    @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared

    @State private var isAddingClaudeAccount = false
    @State private var isAddingCodexAccount = false
    @State private var claudeReconnectError: String?
    @State private var claudeAdminKeyDraft = ""
    @State private var openaiAdminKeyDraft = ""
    @State private var openRouterKeyDraft = ""
    @State private var selectedProviderTab: ServiceType = .claudeCode

    /// Same key ClaudeCodeLocalService reads. OAuth (`/api/oauth/usage`) is the
    /// primary Claude Code usage source and is on by default; turning this off
    /// forces the CLI-output fallback (which no longer renders headlessly).
    @AppStorage(StorageKeys.claudeCodeOAuthFallback)
    private var oauthFallbackEnabled = true

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

    private var showExtraUsageSection: Bool {
        (providerVisibility.isEnabled(.claudeCode) && claudeExtraUsageStatus != nil)
            || providerVisibility.isEnabled(.codexCli)
            || providerVisibility.isEnabled(.grok)
    }

    private var claudeExtraUsageStatus: ExtraUsageStatus? {
        ExtraUsageDisplayPolicy.visibleStatus(
            for: .claudeCode,
            status: dataManager.metrics[.claudeCode]?.extraUsage
        )
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var canScanCosts: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
    }

    private var codexAuthFileDisplayPath: String {
        CodexHomeDirectory.authFileDisplayPath()
    }

    // MARK: - Compact tabbed layout

    /// Compact, MacSweep-style settings: a top tab bar over a fixed-size window
    /// instead of a sidebar. Each tab reuses the existing section builders.
    private var settingsTabView: some View {
        TabView {
            settingsTab {
                trackedProvidersSection
                refreshSection
                notificationsSection
                generalSection
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            settingsTab {
                Picker("Provider", selection: $selectedProviderTab) {
                    ForEach(ServiceType.allCases) { service in
                        Text(service.displayName).tag(service)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, MeterBarTheme.Spacing.xs)

                providerSettingsPane(for: selectedProviderTab)
            }
            .tabItem { Label("Providers", systemImage: "square.grid.2x2") }

            settingsTab {
                if showExtraUsageSection {
                    extraUsageSection
                }
                apiUsageSection
            }
            .tabItem { Label("API Usage", systemImage: "key") }

            settingsTab {
                costTrackingSection
            }
            .tabItem { Label("Cost", systemImage: "chart.bar") }

            if sessionWakeStore.featureEnabled {
                settingsTab {
                    SessionWakeSettingsView()
                }
                .tabItem { Label("Automation", systemImage: "moon.zzz") }
            }

            settingsTab {
                aboutTabContent
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .background {
            // MeterBarDetailBackground now handles safe area internally (material
            // full-bleed, tint inset). The macOS TabView renders its tab strip as
            // a separate control rather than a scroll-under bar, so nothing here
            // scrolls beneath a bar — but this keeps the two windows consistent.
            MeterBarDetailBackground()
        }
    }

    // Compact, fixed window. Wide enough for the provider pane's account rows
    // and usage bars; content is pinned to a leading-aligned column so nothing
    // centers or clips at the window edges.
    private static let windowWidth: CGFloat = 760
    private static let windowHeight: CGFloat = 660

    /// Wraps a tab's content in a padded, scrollable, top-aligned column so
    /// long sections stay reachable in the compact fixed-height window.
    private func settingsTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, MeterBarTheme.Spacing.xl)
            .padding(.vertical, MeterBarTheme.Spacing.xl)
            .frame(width: Self.windowWidth, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var aboutTabContent: some View {
        SettingsPanelSection(title: "About MeterBar", systemImage: "info.circle", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Version",
                detail: "Track your AI coding assistant usage limits from the macOS menu bar."
            ) {
                Text(Self.appVersionString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

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

            SettingsRowView(
                title: "Website",
                detail: "meterbar.dev"
            ) {
                Link("Open", destination: URL(string: "https://meterbar.dev")!)
                    .buttonStyle(.bordered)
            }
        }
        .onAppear { softwareUpdates.refreshState() }
    }

    private static var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return short == build ? short : "\(short) (\(build))"
    }

    private var codexCliSection: some View {
        SettingsPanelSection(title: "OpenAI Codex", logoKind: .codex, color: MeterBarTheme.codexAccent) {
            SettingsRowView(
                title: "Default connection",
                detail: "Reads the OAuth session from \(codexAuthFileDisplayPath)."
            ) {
                HStack(spacing: 8) {
                    StatusPill(
                        title: codexCliService.hasAccess ? "Connected" : "Not Connected",
                        isConnected: codexCliService.hasAccess
                    )

                    Button(codexCliService.hasAccess ? "Refresh" : "Check Again") {
                        // checkAccess does disk I/O — run it off the main actor
                        // (a plain Task would inherit MainActor and block the UI).
                        Task {
                            let service = codexCliService
                            await Task.detached(priority: .userInitiated) { service.checkAccess() }.value
                            await dataManager.refresh(service: .codexCli)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let subscriptionType = codexCliService.subscriptionType, codexCliService.hasAccess {
                SettingsRowView(title: "Plan") {
                    Text(subscriptionType.capitalized)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if !codexCliService.hasAccess {
                EmptyStateCard(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Not connected",
                    message: "Run codex login, then Check Again.",
                    tone: .warning
                )
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Codex Accounts")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        isAddingCodexAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                VStack(spacing: 0) {
                    ForEach(Array(codexAccountStore.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsDivider() }
                        CodexAccountProfileRow(
                            account: account,
                            isConnected: dataManager.codexAccountMetrics[account.id] != nil,
                            onSave: { name, homeDirectory in
                                codexAccountStore.updateAccount(
                                    id: account.id,
                                    name: name,
                                    homeDirectory: homeDirectory
                                )
                                Task { await dataManager.refreshAll() }
                            },
                            onRemove: {
                                codexAccountStore.removeAccount(id: account.id)
                                Task { await dataManager.refreshAll() }
                            }
                        )
                    }
                }
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

    private var extraUsageSection: some View {
        SettingsPanelSection(title: "Extra Usage", systemImage: "creditcard", color: MeterBarTheme.warning) {
            SettingsNotice(
                text: "Extra usage and credits let a provider bill overage beyond your "
                    + "plan once your quota is exhausted. \"Off\" means usage is capped at your subscription.",
                color: .secondary
            )

            if providerVisibility.isEnabled(.claudeCode) {
                if let claudeExtraUsageStatus {
                    extraUsageRow(
                        title: "Claude Code",
                        status: claudeExtraUsageStatus,
                        manageURL: "https://claude.ai/settings"
                    )
                }
            }

            if providerVisibility.isEnabled(.codexCli) {
                extraUsageRow(
                    title: "OpenAI Codex",
                    status: dataManager.metrics[.codexCli]?.extraUsage,
                    manageURL: "https://chatgpt.com"
                )
            }

            if providerVisibility.isEnabled(.grok) {
                extraUsageRow(
                    title: "Grok",
                    status: dataManager.metrics[.grok]?.extraUsage,
                    manageURL: "https://grok.com/?_s=usage"
                )
            }
        }
    }

    private var apiUsageSection: some View {
        SettingsPanelSection(
            title: "API Usage (organization)",
            systemImage: "network",
            color: MeterBarTheme.appAccent
        ) {
            SettingsNotice(
                text: "Paste an organization admin key to estimate pay-as-you-go API cost "
                    + "(Anthropic / OpenAI) from available usage and approximate list rates. "
                    + "Provider usage data may be incomplete and is not a billing statement. "
                    + "Keys are stored in the macOS Keychain and only used against the provider's usage API.",
                color: .secondary
            )

            adminKeyRow(
                provider: .anthropic,
                draft: $claudeAdminKeyDraft,
                placeholder: "sk-ant-admin...",
                helpURL: "https://console.anthropic.com/settings/admin-keys"
            )

            SettingsDivider()

            adminKeyRow(
                provider: .openai,
                draft: $openaiAdminKeyDraft,
                placeholder: "OpenAI admin key",
                helpURL: "https://platform.openai.com/settings/organization/admin-keys"
            )
        }
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

    private var claudeCodeSection: some View {
        SettingsPanelSection(title: "Claude Code (Pro/Max)", logoKind: .claude, color: MeterBarTheme.claudeAccent) {
            SettingsRowView(title: "CLI status") {
                HStack(spacing: 8) {
                    StatusPill(title: claudeCodeService.authState.statusText, isConnected: claudeCodeService.hasAccess)

                    Button(claudeCodeService.hasAccess ? "Refresh" : "Check Again") {
                        // checkAccess can hit the keychain (blocking approval
                        // dialog) — run it off the main actor.
                        Task {
                            let service = claudeCodeService
                            await Task.detached(priority: .userInitiated) { service.checkAccess() }.value
                            if claudeCodeService.hasAccess {
                                await dataManager.refreshAll()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if claudeCodeService.hasAccess {
                if let subscriptionType = claudeCodeService.subscriptionType {
                    SettingsRowView(title: "Plan") {
                        Text(subscriptionType.capitalized)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }

                if let rateLimitTier = claudeCodeService.rateLimitTier {
                    SettingsRowView(title: "Tier") {
                        Text(rateLimitTier.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
            } else {
                EmptyStateCard(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Not connected",
                    message: claudeCodeService.authState.guidanceText,
                    tone: .warning
                )
            }

            SettingsRowView(
                title: "Claude Code OAuth usage",
                detail: "Read usage from Claude Code's Keychain login (the primary source). "
                    + "Off = use only the CLI's `claude /usage` output, which no longer renders headlessly."
            ) {
                Toggle("", isOn: Binding(
                    get: { oauthFallbackEnabled },
                    set: { enabled in
                        oauthFallbackEnabled = enabled
                        // Keychain/file I/O — keep it off the main actor.
                        let service = claudeCodeService
                        Task.detached(priority: .userInitiated) { service.checkAccess() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("Claude Accounts")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Button {
                        isAddingClaudeAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                VStack(spacing: 0) {
                    ForEach(Array(claudeAccountStore.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            SettingsDivider()
                        }
                        AccountProfileRow(
                            account: account,
                            onEnabledChange: { isEnabled in
                                claudeAccountStore.setEnabled(isEnabled, for: account.id)
                                SessionWakeSettingsStore.shared.reconcileAccounts(
                                    available: claudeAccountStore.enabledAccounts.map(\.id)
                                )
                                Task { await dataManager.refreshAll() }
                            },
                            onSave: { name, configDirectory in
                                updateClaudeAccount(id: account.id, name: name, configDirectory: configDirectory)
                            },
                            onReconnect: { reconnectClaudeAccount(account) },
                            onRemove: {
                                claudeAccountStore.removeAccount(id: account.id)
                                Task { await dataManager.refreshAll() }
                            }
                        )
                    }
                }
            }
        }
    }

    private var cursorSection: some View {
        SettingsPanelSection(title: "Cursor", logoKind: .cursor, color: MeterBarTheme.cursorAccent) {
            SettingsRowView(title: "Connection") {
                HStack(spacing: 8) {
                    StatusPill(
                        title: cursorService.hasAccess ? "Connected" : "Not Connected",
                        isConnected: cursorService.hasAccess
                    )

                    Button(cursorService.hasAccess ? "Refresh" : "Check Again") {
                        // forceRescan walks the whole Cursor directory tree —
                        // the worst main-thread stall in the app; run detached.
                        Task {
                            let service = cursorService
                            await Task.detached(priority: .userInitiated) {
                                service.checkAccess(forceRescan: true)
                            }.value
                            if cursorService.hasAccess {
                                await dataManager.refreshAll()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let subscriptionType = cursorService.subscriptionType, cursorService.hasAccess {
                SettingsRowView(title: "Plan") {
                    Text(subscriptionType.capitalized)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if !cursorService.hasAccess {
                EmptyStateCard(
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    title: "Not connected",
                    message: "Log in to Cursor IDE, then Check Again.",
                    tone: .warning
                )
            }
        }
    }

    private var openRouterSection: some View {
        SettingsPanelSection(title: "OpenRouter", logoKind: .openRouter, color: MeterBarTheme.openRouterAccent) {
            SettingsNotice(
                text: "The key is stored in macOS Keychain and sent only to OpenRouter's credits and key APIs.",
                color: .secondary
            )

            SettingsRowView(
                title: "API key",
                detail: openRouterService.hasAccess
                    ? "Configured. Refresh validates access and updates credits."
                    : "Create a key at openrouter.ai/settings/keys."
            ) {
                HStack(spacing: 8) {
                    if openRouterService.hasAccess {
                        StatusPill(title: "Configured", isConnected: true)
                        Button("Remove", role: .destructive) {
                            openRouterService.removeAPIKey()
                            Task { await dataManager.refresh(service: .openRouter) }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        SecureField("sk-or-v1-...", text: $openRouterKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)

                        Button("Save & Validate") {
                            guard openRouterService.saveAPIKey(openRouterKeyDraft) else { return }
                            openRouterKeyDraft = ""
                            providerVisibility.set(.openRouter, isEnabled: true)
                            Task { await dataManager.refresh(service: .openRouter) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button("Get Key") {
                        if let url = URL(string: "https://openrouter.ai/settings/keys") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let error = openRouterService.lastError {
                let detail = switch error {
                case .notAuthenticated:
                    "OpenRouter rejected this key. Remove it and add a valid API key."
                default:
                    error.localizedDescription
                }
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Not connected",
                    message: detail,
                    tone: .warning
                )
            }
        }
    }

    private var grokSection: some View {
        SettingsPanelSection(title: "Grok Build", logoKind: .grok, color: MeterBarTheme.grokAccent) {
            SettingsNotice(
                text: "MeterBar asks the official Grok CLI for billing data over ACP. "
                    + "The CLI owns authentication; MeterBar never reads or stores the cached token.",
                color: .secondary
            )

            SettingsRowView(title: "Connection") {
                HStack(spacing: 8) {
                    StatusPill(
                        title: grokService.hasAccess ? "Connected" : "Not Connected",
                        isConnected: grokService.hasAccess
                    )

                    Button(grokService.hasAccess ? "Refresh" : "Check Again") {
                        Task {
                            let service = grokService
                            await Task.detached(priority: .userInitiated) {
                                service.checkAccess()
                            }.value
                            if grokService.hasAccess {
                                await dataManager.refresh(service: .grok)
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Install / Sign In") {
                        if let url = URL(string: "https://x.ai/cli") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let subscriptionType = grokService.subscriptionType, grokService.hasAccess {
                SettingsRowView(title: "Plan") {
                    Text(subscriptionType)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if !grokService.hasAccess {
                SettingsNotice(
                    text: "Install Grok Build and run `grok login`; no password or API key is entered in MeterBar.",
                    color: MeterBarTheme.warning
                )
            }

            if let error = grokService.lastError {
                SettingsNotice(text: error.localizedDescription, color: MeterBarTheme.warning)
            }
        }
    }

    private var costTrackingSection: some View {
        SettingsPanelSection(title: "Cost Tracking", systemImage: "chart.bar.xaxis", color: MeterBarTheme.success) {
            if costTracker.isScanning {
                SettingsRowView(title: "Status") {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning sessions...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let summary = visibleCostSummary, !summary.costs.isEmpty {
                SettingsRowView(title: "Total cost") {
                    Text(summary.formattedTotalCost)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                SettingsRowView(title: "Daily average") {
                    Text(summary.formattedDailyCost)
                        .foregroundColor(.secondary)
                }

                ForEach(summary.costs) { cost in
                    SettingsRowView(title: cost.provider.displayName) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cost.formattedCost)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("\(cost.formattedTokens) tokens")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let lastScan = costTracker.lastScanDate {
                    SettingsNotice(text: "Last scanned \(formatDate(lastScan)) ago.", color: .secondary)
                }
            } else if costTracker.costSummary != nil {
                // Scanned, but nothing landed for the providers that are enabled.
                EmptyStateCard(
                    systemImage: "tray",
                    title: "No cost data",
                    message: "Enabled providers logged no local tokens in the last 30 days."
                )
            } else {
                // Never scanned this session — the button below kicks off the first scan.
                EmptyStateCard(
                    systemImage: "magnifyingglass",
                    title: "No scan yet",
                    message: "Scan 30 days to estimate local token cost."
                )
            }

            if !canScanCosts {
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Nothing to scan",
                    message: "Enable Claude Code or OpenAI Codex to scan local token logs.",
                    tone: .warning
                )
            }

            SettingsRowView(title: "Local sessions") {
                Button {
                    Task {
                        await costTracker.scanCosts(days: 30)
                    }
                } label: {
                    HStack(spacing: 7) {
                        if costTracker.isRefreshInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                            Text(costTracker.isRefreshingMissingDays ? "Updating..." : "Scanning...")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("Scan 30 Days")
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(costTracker.isRefreshInProgress || !canScanCosts)
            }
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
                .buttonStyle(.glass)
            }
        }
    }

    private func providerSettingsPane(for service: ServiceType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            providerHeader(for: service)
            providerInfoSection(for: service)
            providerUsageSection(for: service)
            providerSpecificSettings(for: service)
        }
    }

    private func providerHeader(for service: ServiceType) -> some View {
        DashboardTile(padding: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProviderLogoView(
                    kind: .forService(service),
                    size: 26,
                    foregroundColor: MeterBarTheme.accent(for: service)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(providerSourceText(for: service))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Button {
                    refreshProvider(service)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh \(service.displayName)")
                .disabled(dataManager.isLoading)

                Toggle("", isOn: providerEnabledBinding(for: service))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private func providerInfoSection(for service: ServiceType) -> some View {
        SettingsPanelSection(
            title: "Overview",
            logoKind: .forService(service),
            color: MeterBarTheme.accent(for: service)
        ) {
            SettingsInfoRow(label: "Source", value: providerSourceText(for: service))
            SettingsInfoRow(label: "Updated", value: providerUpdatedText(for: service))
            SettingsInfoRow(label: "Status", value: providerStatusText(for: service))

            if let plan = providerPlanText(for: service) {
                SettingsInfoRow(label: "Plan", value: plan)
            }

            if let error = providerErrorText(for: service) {
                SettingsNotice(text: error, color: MeterBarTheme.warning)
            }
        }
    }

    private func providerUsageSection(for service: ServiceType) -> some View {
        SettingsPanelSection(
            title: "Usage",
            systemImage: "chart.bar.xaxis",
            color: MeterBarTheme.accent(for: service)
        ) {
            let snapshots = providerSnapshots(for: service).filter(\.hasMetrics)
            if snapshots.isEmpty {
                if providerVisibility.isEnabled(service) {
                    EmptyStateCard(
                        systemImage: "chart.bar",
                        title: "No usage yet",
                        message: "Refresh after signing in to see \(service.displayName) usage."
                    )
                } else {
                    EmptyStateCard(
                        systemImage: "eye.slash",
                        title: "Provider disabled",
                        message: "Enable \(service.displayName) to track its usage."
                    )
                }
            } else {
                ForEach(snapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 10) {
                        if snapshots.count > 1 {
                            ProviderTitle(
                                title: snapshot.title,
                                logoKind: snapshot.logoKind,
                                color: snapshot.accentColor,
                                font: .subheadline
                            )
                        }

                        if snapshot.detailLimits.isEmpty {
                            EmptyStateCard(
                                systemImage: "clock.badge.questionmark",
                                title: "No quota windows",
                                message: "This provider didn't report any limit windows."
                            )
                        } else {
                            ForEach(snapshot.detailLimits) { limit in
                                LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .regular)
                            }
                        }

                        let badges = ProviderStatusBadges(snapshot: snapshot, style: .regular)
                        if badges.hasContent {
                            badges
                        }
                    }
                    .padding(.vertical, snapshots.count > 1 ? 4 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func providerSpecificSettings(for service: ServiceType) -> some View {
        switch service {
        case .claudeCode:
            claudeCodeSection
            providerExtraUsageSection(for: service)
        case .codexCli:
            codexCliSection
            providerExtraUsageSection(for: service)
        case .cursor:
            cursorSection
        case .openRouter:
            openRouterSection
        case .grok:
            grokSection
            providerExtraUsageSection(for: service)
        }
    }

    @ViewBuilder
    private func providerExtraUsageSection(for service: ServiceType) -> some View {
        switch service {
        case .claudeCode:
            if let claudeExtraUsageStatus {
                SettingsPanelSection(title: "Extra Usage", systemImage: "creditcard", color: MeterBarTheme.warning) {
                    extraUsageRow(
                        title: "Claude Code",
                        status: claudeExtraUsageStatus,
                        manageURL: "https://claude.ai/settings"
                    )
                }
            }
        case .codexCli:
            SettingsPanelSection(title: "Credits", systemImage: "creditcard", color: MeterBarTheme.warning) {
                extraUsageRow(
                    title: "OpenAI Codex",
                    status: dataManager.metrics[.codexCli]?.extraUsage,
                    manageURL: "https://chatgpt.com"
                )
            }
        case .cursor:
            EmptyView()
        case .openRouter:
            EmptyView()
        case .grok:
            SettingsPanelSection(title: "Extra Usage", systemImage: "creditcard", color: MeterBarTheme.warning) {
                extraUsageRow(
                    title: "Grok",
                    status: dataManager.metrics[.grok]?.extraUsage,
                    manageURL: "https://grok.com/?_s=usage"
                )
            }
        }
    }

    private func extraUsageRow(title: String, status: ExtraUsageStatus?, manageURL: String) -> some View {
        SettingsRowView(title: title, detail: extraUsageDetailText(status)) {
            HStack(spacing: 8) {
                ExtraUsageStatusPill(status: status ?? .unknown)

                Button("Manage") {
                    if let url = URL(string: manageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .help("Open \(manageURL) to change extra usage settings")
            }
        }
    }

    private func adminKeyRow(
        provider: ApiProvider,
        draft: Binding<String>,
        placeholder: String,
        helpURL: String
    ) -> some View {
        let connected = authManager.isAuthenticated(provider)
        return AdminKeySettingsRow(
            provider: provider,
            connected: connected,
            draft: draft,
            placeholder: placeholder,
            onSave: {
                saveAdminKey(provider, draft: draft)
            },
            onRemove: {
                authManager.removeAdminKey(for: provider)
                Task { await apiUsageStore.refresh() }
            },
            onHelp: {
                if let url = URL(string: helpURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        )
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

    private func providerSnapshots(for service: ServiceType) -> [ProviderSnapshot] {
        providerSnapshots.filter { $0.service == service }
    }

    private func providerEnabledBinding(for service: ServiceType) -> Binding<Bool> {
        Binding(
            get: { providerVisibility.isEnabled(service) },
            set: { isEnabled in
                providerVisibility.set(service, isEnabled: isEnabled)
                Task {
                    await dataManager.refreshAll()
                }
            }
        )
    }

    private func refreshProvider(_ service: ServiceType) {
        Task {
            // Access checks do disk/keychain I/O; a plain Task inherits the
            // main actor here, so hop to a detached task for the check itself.
            let claudeCode = claudeCodeService
            let codexCli = codexCliService
            let cursor = cursorService
            let grok = grokService
            await Task.detached(priority: .userInitiated) {
                switch service {
                case .claudeCode:
                    claudeCode.checkAccess()
                case .codexCli:
                    codexCli.checkAccess()
                case .cursor:
                    cursor.checkAccess(forceRescan: true)
                case .openRouter:
                    break
                case .grok:
                    grok.checkAccess()
                }
            }.value
            await dataManager.refresh(service: service)
        }
    }

    private func providerSourceText(for service: ServiceType) -> String {
        switch service {
        case .claudeCode:
            "Claude CLI /usage"
        case .codexCli:
            "\(codexAuthFileDisplayPath) + ChatGPT usage API"
        case .cursor:
            "Cursor local state + usage API"
        case .openRouter:
            "OpenRouter credits + key APIs"
        case .grok:
            "Grok Build ACP billing"
        }
    }

    private func providerUpdatedText(for service: ServiceType) -> String {
        providerSnapshots(for: service)
            .filter(\.hasMetrics)
            .map(\.updatedText)
            .first ?? "No data"
    }

    private func providerStatusText(for service: ServiceType) -> String {
        guard providerVisibility.isEnabled(service) else {
            return "Disabled"
        }
        guard providerHasAccess(service) else {
            return "Not connected"
        }
        if providerErrorText(for: service) != nil {
            return "Refresh failed"
        }
        if let band = providerSnapshots(for: service).compactMap(\.band).max(by: { $0.severity < $1.severity }) {
            return band.shortLabel
        }
        return "Waiting for refresh"
    }

    private func providerStatusColor(for service: ServiceType) -> Color {
        guard providerVisibility.isEnabled(service), providerHasAccess(service) else {
            return .secondary
        }
        if providerErrorText(for: service) != nil {
            return MeterBarTheme.warning
        }
        if let band = providerSnapshots(for: service).compactMap(\.band).max(by: { $0.severity < $1.severity }) {
            return band.color
        }
        return .secondary
    }

    private func providerPlanText(for service: ServiceType) -> String? {
        switch service {
        case .claudeCode:
            let plan = claudeCodeService.subscriptionType?.capitalized
            let tier = claudeCodeService.rateLimitTier?
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return [plan, tier].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .codexCli:
            return codexCliService.subscriptionType?.capitalized.nilIfEmpty
        case .cursor:
            return cursorService.subscriptionType?.capitalized.nilIfEmpty
        case .openRouter:
            return nil
        case .grok:
            return grokService.subscriptionType?.nilIfEmpty
        }
    }

    private func providerHasAccess(_ service: ServiceType) -> Bool {
        switch service {
        case .claudeCode:
            claudeCodeService.hasAccess
        case .codexCli:
            codexCliService.hasAccess
        case .cursor:
            cursorService.hasAccess
        case .openRouter:
            openRouterService.hasAccess
        case .grok:
            grokService.hasAccess
        }
    }

    private func providerErrorText(for service: ServiceType) -> String? {
        switch service {
        case .claudeCode:
            claudeCodeService.lastError?.localizedDescription
        case .codexCli:
            codexCliService.lastError?.localizedDescription
        case .cursor:
            cursorService.lastError?.localizedDescription
        case .openRouter:
            openRouterService.lastError?.localizedDescription
        case .grok:
            grokService.lastError?.localizedDescription
        }
    }

    private func extraUsageDetailText(_ status: ExtraUsageStatus?) -> String {
        guard let status else {
            return "Waiting for refresh."
        }
        switch status.state {
        case .on:
            return status.detail.map { "Enabled · \($0)" } ?? "Enabled — overage can be billed beyond your plan."
        case .off:
            return "Disabled — capped at your subscription quota."
        case .unknown:
            return "Could not determine. Sign in to the CLI and refresh."
        }
    }

    private func saveAdminKey(_ provider: ApiProvider, draft: Binding<String>) {
        guard authManager.setAdminKey(draft.wrappedValue, for: provider) else {
            return
        }
        draft.wrappedValue = ""
        Task { await apiUsageStore.refresh() }
    }

    private func formatDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }

    private func addClaudeAccount(name: String, configDirectory: String) {
        claudeAccountStore.addAccount(
            name: name,
            configDirectory: configDirectory
        )
        Task {
            await dataManager.refreshAll()
        }
    }

    private func updateClaudeAccount(id: UUID, name: String, configDirectory: String?) {
        claudeAccountStore.updateAccount(id: id, name: name, configDirectory: configDirectory)
        Task { await dataManager.refreshAll() }
    }

    private func reconnectClaudeAccount(_ account: ClaudeCodeAccount) {
        do {
            try ClaudeCodeReconnectService.openReconnectTerminal(for: account)
        } catch {
            claudeReconnectError = error.localizedDescription
        }
    }
}

// MARK: - SettingsInfoRow

private struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(width: SettingsRowViewMetrics.labelWidth, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsPanelSection

struct SettingsPanelSection<Content: View>: View {
    // MARK: Lifecycle

    init(
        title: String,
        logoKind: ProviderLogoKind,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = logoKind
        self.systemImage = nil
        self.color = color
        self.content = content()
    }

    init(
        title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.logoKind = nil
        self.systemImage = systemImage
        self.color = color
        self.content = content()
    }

    // MARK: Internal

    let title: String
    let logoKind: ProviderLogoKind?
    let systemImage: String?
    let color: Color
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let logoKind {
                    ProviderLogoView(kind: logoKind, size: 14, foregroundColor: color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                }
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(.semibold)

            DashboardTile(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - SettingsRowViewMetrics

enum SettingsRowViewMetrics {
    static let labelWidth: CGFloat = 190
}

// MARK: - SettingsRowView

struct SettingsRowView<Content: View>: View {
    // MARK: Lifecycle

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    // MARK: Internal

    let title: String
    let detail: String?
    let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: SettingsRowViewMetrics.labelWidth, alignment: .leading)
            // Read the title and its explanatory detail as one VoiceOver element
            // rather than two adjacent fragments. The trailing control stays a
            // separate focusable element so its own label/actuation are intact.
            .accessibilityElement(children: .combine)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsNotice

struct SettingsNotice: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SettingsDivider

struct SettingsDivider: View {
    var body: some View {
        Divider()
    }
}

// MARK: - StatusPill

private struct StatusPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        Label(title, systemImage: isConnected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isConnected ? MeterBarTheme.success : Color.secondary)
            .font(.subheadline)
    }
}

// MARK: - AdminKeySettingsRow

private struct AdminKeySettingsRow: View {
    // MARK: Internal

    let provider: ApiProvider
    let connected: Bool
    @Binding var draft: String

    let placeholder: String
    let onSave: () -> Void
    let onRemove: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(connected ? connectedMessage : "Required for organization usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(title: connected ? "Connected" : "Not Connected", isConnected: connected)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                if connected {
                    SettingsReadonlyField(text: "••••••••••••••••")

                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                } else {
                    SecureField(placeholder, text: $draft)
                        .settingsInput()
                        .frame(minWidth: 220, maxWidth: 340)

                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedDraft.isEmpty)

                    Button(action: onHelp) {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Where to create this admin API key")
                }
            }
        }
        .padding(.vertical, MeterBarTheme.Spacing.sm)
    }

    // MARK: Private

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectedMessage: String {
        "Connected. Estimated usage appears on the API cost card."
    }
}

// MARK: - AddCodexAccountSheet

private struct AddCodexAccountSheet: View {
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: .codex, size: 18, foregroundColor: MeterBarTheme.codexAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Codex Account").font(.headline)
                    Text("Use a separate CODEX_HOME containing its own auth.json.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Account name", text: $accountName).settingsInput()
                HStack(spacing: 8) {
                    TextField("Codex home directory", text: $homeDirectory).settingsInput()
                    Button("Choose", action: chooseHomeDirectory).buttonStyle(.bordered)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Account") {
                    onAdd(trimmedName, trimmedHomeDirectory)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(MeterBarTheme.Spacing.xxl)
        .frame(width: 520)
    }

    @Environment(\.dismiss)
    private var dismiss
    @State private var accountName = ""
    @State private var homeDirectory = ""

    private var trimmedName: String { accountName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHomeDirectory: String {
        homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canAdd: Bool { !trimmedName.isEmpty && !trimmedHomeDirectory.isEmpty }

    private func chooseHomeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            homeDirectory = url.path
            if trimmedName.isEmpty { accountName = url.lastPathComponent }
        }
    }
}

// MARK: - AddClaudeAccountSheet

private struct AddClaudeAccountSheet: View {
    // MARK: Internal

    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: .claude, size: 18, foregroundColor: MeterBarTheme.claudeAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Claude Account")
                        .font(.headline)
                    Text("Use a separate CLAUDE_CONFIG_DIR for this profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Work", text: $accountName)
                        .settingsInput()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Config directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Path", text: $configDirectory)
                            .settingsInput()
                        Button("Choose") {
                            chooseConfigDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Account") {
                    guard canAdd else {
                        return
                    }
                    onAdd(trimmedName, trimmedConfigDirectory)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(MeterBarTheme.Spacing.xxl)
        .frame(width: 520)
    }

    // MARK: Private

    @Environment(\.dismiss)
    private var dismiss

    @State private var accountName = ""
    @State private var configDirectory = ""

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConfigDirectory: String {
        configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty && !trimmedConfigDirectory.isEmpty
    }

    private func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            configDirectory = url.path
            if trimmedName.isEmpty {
                accountName = url.lastPathComponent
            }
        }
    }
}

// MARK: - AccountProfileRow

private enum AccountProfileRowMetrics {
    static let labelWidth: CGFloat = 126
    static let fieldWidth: CGFloat = 280
    static let actionWidth: CGFloat = 28
}

private struct AccountProfileRow: View {
    // MARK: Lifecycle

    init(
        account: ClaudeCodeAccount,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onReconnect: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onReconnect = onReconnect
        self.onRemove = onRemove
        _nameDraft = State(initialValue: account.name)
        _configDirectoryDraft = State(initialValue: account.configDirectory ?? "")
    }

    // MARK: Internal

    let account: ClaudeCodeAccount
    let onEnabledChange: (Bool) -> Void
    let onSave: (String, String?) -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.claudeAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    accountFieldLabel("Account name")

                    TextField("Account label", text: $nameDraft)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .onSubmit(saveChanges)

                    // Migrated to the shared `MeterBarChip`. This was the 5th,
                    // odd-one-out recipe (`.thinMaterial` + glassCardStroke); the
                    // `.glass` chip gives it the standard Liquid-Glass capsule
                    // while keeping the Default/Profile role tint.
                    MeterBarChip(
                        account.isDefault ? "Default" : "Profile",
                        tint: account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.claudeAccent,
                        style: .glass
                    )
                }

                HStack(spacing: 8) {
                    accountFieldLabel(account.isDefault ? "Default config directory" : "Config directory")

                    if account.isDefault {
                        SettingsReadonlyField(text: displayConfigDirectory)

                        Button {
                            revealDefaultConfigDirectory()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Reveal config directory in Finder")
                    } else {
                        HStack(spacing: 8) {
                            TextField("Config directory", text: $configDirectoryDraft)
                                .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                                .onSubmit(saveChanges)

                            Button {
                                chooseConfigDirectory()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.bordered)
                            .help("Choose config directory")
                        }
                    }
                }

                if account.isDefault {
                    Text("Mirrors the Claude CLI default (~/.claude, or $CLAUDE_CONFIG_DIR)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, AccountProfileRowMetrics.labelWidth + 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { account.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(account.isEnabled ? "Disable account" : "Enable account")

                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .help("Reconnect Claude profile")

                Button(action: saveChanges) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .disabled(!hasChanges || !canSave)
                .help("Save account changes")

                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: AccountProfileRowMetrics.actionWidth)
                    .help("Delete account")
                } else {
                    Color.clear
                        .frame(width: AccountProfileRowMetrics.actionWidth, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, MeterBarTheme.Spacing.md)
        .onChange(of: account) { _, updatedAccount in
            nameDraft = updatedAccount.name
            configDirectoryDraft = updatedAccount.configDirectory ?? ""
        }
    }

    // MARK: Private

    @State private var nameDraft: String
    @State private var configDirectoryDraft: String

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConfigDirectory: String {
        configDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayConfigDirectory: String {
        account.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.configDirectory ?? ""
            : ClaudeCodeAccount.defaultConfigDirectory()
    }

    private var hasChanges: Bool {
        trimmedName != account.name ||
            (!account.isDefault && trimmedConfigDirectory != (account.configDirectory ?? ""))
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (account.isDefault || !trimmedConfigDirectory.isEmpty)
    }

    private func saveChanges() {
        guard hasChanges, canSave else {
            return
        }
        onSave(trimmedName, account.isDefault ? nil : trimmedConfigDirectory)
    }

    private func accountFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(width: AccountProfileRowMetrics.labelWidth, alignment: .leading)
    }

    private func revealDefaultConfigDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: ClaudeCodeAccount.defaultConfigDirectory(), isDirectory: true)
        ])
    }

    private func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            configDirectoryDraft = url.path
        }
    }
}

private struct CodexAccountProfileRow: View {
    init(
        account: CodexAccount,
        isConnected: Bool,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.isConnected = isConnected
        self.onSave = onSave
        self.onRemove = onRemove
        _nameDraft = State(initialValue: account.name)
        _homeDirectoryDraft = State(initialValue: account.homeDirectory ?? "")
    }

    let account: CodexAccount
    let isConnected: Bool
    let onSave: (String, String?) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.codexAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Account label", text: $nameDraft)
                        .settingsInput(width: 240)
                        .onSubmit(saveChanges)
                    Text(account.isDefault ? "Default" : "Profile")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.codexAccent)
                    StatusPill(title: isConnected ? "Connected" : "Not Connected", isConnected: isConnected)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Text("CODEX_HOME")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 126, alignment: .leading)
                    if account.isDefault {
                        SettingsReadonlyField(text: CodexHomeDirectory.path(for: account))
                    } else {
                        TextField("Codex home directory", text: $homeDirectoryDraft)
                            .settingsInput(width: 280)
                            .onSubmit(saveChanges)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: saveChanges) { Image(systemName: "checkmark") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasChanges || !canSave)
                    .help("Save account changes")
                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete account")
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, MeterBarTheme.Spacing.md)
        .onChange(of: account) { _, updated in
            nameDraft = updated.name
            homeDirectoryDraft = updated.homeDirectory ?? ""
        }
    }

    @State private var nameDraft: String
    @State private var homeDirectoryDraft: String

    private var trimmedName: String { nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHomeDirectory: String {
        homeDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasChanges: Bool {
        trimmedName != account.name || (!account.isDefault && trimmedHomeDirectory != account.homeDirectory)
    }
    private var canSave: Bool { !trimmedName.isEmpty && (account.isDefault || !trimmedHomeDirectory.isEmpty) }

    private func saveChanges() {
        guard hasChanges, canSave else { return }
        onSave(trimmedName, account.isDefault ? nil : trimmedHomeDirectory)
    }
}

// MARK: - SettingsReadonlyField

private struct SettingsReadonlyField: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .settingsInputSurface(width: 280)
            .help(text)
    }
}

// MARK: - SettingsInputModifier

private struct SettingsInputModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(1)
            .settingsInputSurface(width: width)
    }
}

// MARK: - SettingsInputSurfaceModifier

private struct SettingsInputSurfaceModifier: ViewModifier {
    let width: CGFloat?
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        // The capsule variant moved to `MeterBarChip(style: .glass)`; this
        // surface now only backs rounded-rectangle settings input fields.
        let roundedRectangle = RoundedRectangle(cornerRadius: MeterBarTheme.Radius.medium, style: .continuous)

        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(width: width)
            .background(.thinMaterial, in: roundedRectangle)
            .overlay {
                roundedRectangle.stroke(MeterBarTheme.glassCardStroke, lineWidth: 0.5)
            }
    }
}

private extension View {
    func settingsInput(width: CGFloat? = nil) -> some View {
        modifier(SettingsInputModifier(width: width))
    }

    func settingsInputSurface(
        width: CGFloat? = nil,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 6
    ) -> some View {
        modifier(
            SettingsInputSurfaceModifier(
                width: width,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}

private extension QuotaBand {
    var severity: Int {
        switch self {
        case .healthy:
            0
        case .tight:
            1
        case .critical:
            2
        case .exhausted:
            3
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
