import SwiftUI
import AppKit
import MeterBarShared

struct SettingsView: View {
    let embeddedInDashboard: Bool

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared

    @State private var newClaudeAccountName: String = ""
    @State private var newClaudeConfigDirectory: String = ""
    @State private var claudeReconnectError: String?
    @State private var claudeAdminKeyDraft: String = ""
    @State private var openaiAdminKeyDraft: String = ""

    /// Same key ClaudeCodeLocalService reads. Previously this flag was only
    /// settable via `defaults write`; exposing it here makes the legacy OAuth
    /// fallback discoverable instead of a hidden switch.
    @AppStorage(StorageKeys.claudeCodeOAuthFallback)
    private var oauthFallbackEnabled = false

    init(embeddedInDashboard: Bool = false) {
        self.embeddedInDashboard = embeddedInDashboard
    }

    var body: some View {
        Form {
            trackedProvidersSection
            if providerVisibility.isEnabled(.claudeCode) {
                claudeCodeSection
            }
            if providerVisibility.isEnabled(.cursor) {
                cursorSection
            }
            if showExtraUsageSection {
                extraUsageSection
            }
            apiUsageSection
            costTrackingSection
            refreshSection
            generalSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(embeddedInDashboard ? .hidden : .automatic)
        .background(embeddedInDashboard ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: embeddedInDashboard ? nil : 560,
            minHeight: embeddedInDashboard ? nil : 500
        )
        .alert(
            "Claude Reconnect Failed",
            isPresented: Binding(
                get: { claudeReconnectError != nil },
                set: { isPresented in
                    if !isPresented { claudeReconnectError = nil }
                }
            )
        ) {
            Button("OK") { claudeReconnectError = nil }
        } message: {
            Text(claudeReconnectError ?? "Could not open the Claude reconnect flow.")
        }
    }

    private var generalSection: some View {
        SettingsPanelSection(title: "General", systemImage: "dock.rectangle", color: MeterBarTheme.appAccent) {
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
        }
    }

    private var showExtraUsageSection: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
    }

    private var extraUsageSection: some View {
        SettingsPanelSection(title: "Extra Usage", systemImage: "creditcard", color: MeterBarTheme.warning) {
            SettingsNotice(
                text: "Extra usage (Claude) and credits (Codex) let a provider bill overage beyond your "
                    + "plan once your quota is exhausted. \"Off\" means usage is capped at your subscription.",
                color: .secondary
            )

            if providerVisibility.isEnabled(.claudeCode) {
                extraUsageRow(
                    title: "Claude Code",
                    status: dataManager.metrics[.claudeCode]?.extraUsage,
                    manageURL: "https://claude.ai/settings"
                )
            }

            if providerVisibility.isEnabled(.codexCli) {
                extraUsageRow(
                    title: "OpenAI Codex",
                    status: dataManager.metrics[.codexCli]?.extraUsage,
                    manageURL: "https://chatgpt.com"
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

    private func extraUsageDetailText(_ status: ExtraUsageStatus?) -> String {
        guard let status else { return "Waiting for refresh." }
        switch status.state {
        case .on:
            return status.detail.map { "Enabled · \($0)" } ?? "Enabled — overage can be billed beyond your plan."
        case .off:
            return "Disabled — capped at your subscription quota."
        case .unknown:
            return "Could not determine. Sign in to the CLI and refresh."
        }
    }

    private var apiUsageSection: some View {
        SettingsPanelSection(
            title: "API Usage (organization)",
            systemImage: "network",
            color: MeterBarTheme.appAccent
        ) {
            SettingsNotice(
                text: "Paste an organization admin key to show your pay-as-you-go API spend "
                    + "(Anthropic / OpenAI) as its own card, separate from subscription quotas. "
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

    private func adminKeyRow(
        provider: ApiProvider,
        draft: Binding<String>,
        placeholder: String,
        helpURL: String
    ) -> some View {
        let connected = authManager.isAuthenticated(provider)
        return SettingsRowView(
            title: provider.displayName,
            detail: connected ? "Connected. Usage appears on the API card." : "Required for organization usage."
        ) {
            HStack(spacing: 8) {
                StatusPill(title: connected ? "Connected" : "Not Connected", isConnected: connected)

                SecureField(placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Button("Save") {
                    saveAdminKey(provider, draft: draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove") {
                    authManager.removeAdminKey(for: provider)
                    Task { await apiUsageStore.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(!connected)

                Button("Help") {
                    if let url = URL(string: helpURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .help("Open \(helpURL)")
            }
        }
    }

    private func saveAdminKey(_ provider: ApiProvider, draft: Binding<String>) {
        guard authManager.setAdminKey(draft.wrappedValue, for: provider) else { return }
        draft.wrappedValue = ""
        Task { await apiUsageStore.refresh() }
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
        }
    }

    private var claudeCodeSection: some View {
        SettingsPanelSection(title: "Claude Code (Pro/Max)", logoKind: .claude, color: MeterBarTheme.claudeAccent) {
            SettingsRowView(title: "CLI status") {
                HStack(spacing: 8) {
                    StatusPill(title: claudeCodeService.authState.statusText, isConnected: claudeCodeService.hasAccess)

                    Button(claudeCodeService.hasAccess ? "Refresh" : "Check Again") {
                        claudeCodeService.checkAccess()
                        if claudeCodeService.hasAccess {
                            Task {
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
                SettingsNotice(
                    text: claudeCodeService.authState.guidanceText,
                    color: .secondary
                )
                SettingsNotice(
                    text: "MeterBar reads Claude CLI usage output before any legacy OAuth fallback.",
                    color: MeterBarTheme.warning
                )
            }

            SettingsRowView(
                title: "Legacy OAuth fallback",
                detail: "When the Claude CLI is unavailable, read usage via Claude Code's OAuth token."
            ) {
                Toggle("", isOn: Binding(
                    get: { oauthFallbackEnabled },
                    set: { enabled in
                        oauthFallbackEnabled = enabled
                        claudeCodeService.checkAccess()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Accounts")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                List {
                    ForEach(claudeAccountStore.accounts) { account in
                        AccountProfileRow(
                            account: account,
                            onSave: { name, configDirectory in
                                updateClaudeAccount(id: account.id, name: name, configDirectory: configDirectory)
                            },
                            onReconnect: { reconnectClaudeAccount(account) },
                            onRemove: {
                                claudeAccountStore.removeAccount(id: account.id)
                                Task { await dataManager.refreshAll() }
                            }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    .onMove(perform: moveClaudeAccounts)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: claudeAccountListHeight)
            }

            SettingsRowView(title: "New account") {
                TextField("Account name", text: $newClaudeAccountName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }

            SettingsRowView(
                title: "Config directory",
                detail: "Use a separate CLAUDE_CONFIG_DIR for each extra account."
            ) {
                HStack(spacing: 8) {
                    TextField("Path", text: $newClaudeConfigDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    Button("Choose") {
                        chooseClaudeConfigDirectory()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsRowView(title: "Add profile") {
                Button("Add Account") {
                    addClaudeAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddClaudeAccount)
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
                        cursorService.checkAccess(forceRescan: true)
                        if cursorService.hasAccess {
                            Task {
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
                SettingsNotice(
                    text: "Reads Cursor IDE credentials from Cursor's local state database.",
                    color: .secondary
                )
                SettingsNotice(text: "Log in to Cursor IDE first, then check again.", color: MeterBarTheme.warning)
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
                SettingsNotice(text: "No cost data for enabled providers.", color: .secondary)
            } else {
                SettingsNotice(text: "No cost data loaded yet.", color: .secondary)
            }

            if !canScanCosts {
                SettingsNotice(
                    text: "Enable Claude Code or OpenAI Codex to scan local token logs.",
                    color: MeterBarTheme.warning
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
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.bordered)
            }
        }
    }

    private var canAddClaudeAccount: Bool {
        !newClaudeAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !newClaudeConfigDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleCostSummary: CostSummary? {
        costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
    }

    private var canScanCosts: Bool {
        providerVisibility.isEnabled(.claudeCode) || providerVisibility.isEnabled(.codexCli)
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

    private func formatDate(_ date: Date) -> String {
        UsageFormat.relative(date)
    }

    private func addClaudeAccount() {
        claudeAccountStore.addAccount(
            name: newClaudeAccountName,
            configDirectory: newClaudeConfigDirectory
        )
        newClaudeAccountName = ""
        newClaudeConfigDirectory = ""
        Task {
            await dataManager.refreshAll()
        }
    }

    private func chooseClaudeConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            newClaudeConfigDirectory = url.path
            if newClaudeAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newClaudeAccountName = url.lastPathComponent
            }
        }
    }

    private var claudeAccountListHeight: CGFloat {
        min(320, max(84, CGFloat(claudeAccountStore.accounts.count) * 84))
    }

    private func updateClaudeAccount(id: UUID, name: String, configDirectory: String?) {
        claudeAccountStore.updateAccount(id: id, name: name, configDirectory: configDirectory)
        Task { await dataManager.refreshAll() }
    }

    private func moveClaudeAccounts(from source: IndexSet, to destination: Int) {
        claudeAccountStore.moveAccounts(fromOffsets: source, toOffset: destination)
    }

    private func reconnectClaudeAccount(_ account: ClaudeCodeAccount) {
        do {
            try ClaudeCodeReconnectService.openReconnectTerminal(for: account)
        } catch {
            claudeReconnectError = error.localizedDescription
        }
    }
}

private struct SettingsPanelSection<Content: View>: View {
    let title: String
    let logoKind: ProviderLogoKind?
    let systemImage: String?
    let color: Color
    let content: Content

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

    var body: some View {
        Section {
            content
        } header: {
            HStack(spacing: 6) {
                if let logoKind {
                    ProviderLogoView(kind: logoKind, size: 14, foregroundColor: color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                }
                Text(title)
            }
        }
    }
}

private struct SettingsRowView<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SettingsNotice: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
    }
}

private struct StatusPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        Label(title, systemImage: isConnected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isConnected ? MeterBarTheme.success : Color.secondary)
            .font(.subheadline)
    }
}

private struct AccountProfileRow: View {
    let account: ClaudeCodeAccount
    let onSave: (String, String?) -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    @State private var nameDraft: String
    @State private var configDirectoryDraft: String

    init(
        account: ClaudeCodeAccount,
        onSave: @escaping (String, String?) -> Void,
        onReconnect: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.onSave = onSave
        self.onReconnect = onReconnect
        self.onRemove = onRemove
        _nameDraft = State(initialValue: account.name)
        _configDirectoryDraft = State(initialValue: account.configDirectory ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .padding(.top, 8)
                .help("Drag to reorder")

            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.claudeAccent)
                .frame(width: 18)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Account label", text: $nameDraft)
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(saveChanges)

                if account.isDefault {
                    Text("Default Claude CLI profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    TextField("Config directory", text: $configDirectoryDraft)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit(saveChanges)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Reconnect Claude profile")

                Button(action: saveChanges) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .disabled(!hasChanges || !canSave)
                .help("Save account changes")

                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Delete account")
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: account) { _, updatedAccount in
            nameDraft = updatedAccount.name
            configDirectoryDraft = updatedAccount.configDirectory ?? ""
        }
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConfigDirectory: String {
        configDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != account.name ||
            (!account.isDefault && trimmedConfigDirectory != (account.configDirectory ?? ""))
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (account.isDefault || !trimmedConfigDirectory.isEmpty)
    }

    private func saveChanges() {
        guard hasChanges, canSave else { return }
        onSave(trimmedName, account.isDefault ? nil : trimmedConfigDirectory)
    }
}
