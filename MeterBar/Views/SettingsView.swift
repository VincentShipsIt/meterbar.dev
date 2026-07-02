import SwiftUI
import MeterBarShared
import AppKit

struct SettingsView: View {
    let embeddedInDashboard: Bool

    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var costTracker = CostTracker.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var dockVisibility = DockVisibilityStore.shared

    @State private var claudeAdminKey: String = ""
    @State private var openaiAdminKey: String = ""
    @State private var newClaudeAccountName: String = ""
    @State private var newClaudeConfigDirectory: String = ""

    @State private var showingClaudeHelp = false
    @State private var showingOpenAIHelp = false

    init(embeddedInDashboard: Bool = false) {
        self.embeddedInDashboard = embeddedInDashboard
    }

    var body: some View {
        Form {
            trackedProvidersSection
            if providerVisibility.isEnabled(.claude) {
                claudeAdminSection
            }
            if providerVisibility.isEnabled(.claudeCode) {
                claudeCodeSection
            }
            if providerVisibility.isEnabled(.openai) {
                openAISection
            }
            if providerVisibility.isEnabled(.cursor) {
                cursorSection
            }
            if showExtraUsageSection {
                extraUsageSection
            }
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
        .sheet(isPresented: $showingClaudeHelp) {
            ClaudeHelpView()
        }
        .sheet(isPresented: $showingOpenAIHelp) {
            OpenAIHelpView()
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
            SettingsDivider()
            providerToggleRow(
                title: "Claude Admin API",
                detail: "Optional organization usage API source.",
                service: .claude
            )
            providerToggleRow(
                title: "OpenAI Admin API",
                detail: "Optional platform usage API source.",
                service: .openai
            )
        }
    }

    private var claudeAdminSection: some View {
        SettingsPanelSection(title: "Claude (Anthropic)", logoKind: .claude, color: MeterBarTheme.claudeAccent) {
            SettingsRowView(title: "Connection") {
                StatusPill(
                    title: authManager.isClaudeAuthenticated ? "Connected" : "Not Connected",
                    isConnected: authManager.isClaudeAuthenticated
                )
            }

            SettingsRowView(title: "Admin API Key", detail: "Required for organization usage APIs.") {
                SecureField("sk-ant-admin...", text: $claudeAdminKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
            }

            SettingsRowView(title: "Actions") {
                HStack(spacing: 8) {
                    Button("Save") {
                        _ = authManager.setClaudeAdminKey(claudeAdminKey)
                        claudeAdminKey = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(claudeAdminKey.isEmpty)

                    Button("Remove", role: .destructive) {
                        authManager.removeClaudeAdminKey()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!authManager.isClaudeAuthenticated)

                    Button("Help") {
                        showingClaudeHelp = true
                    }
                    .buttonStyle(.bordered)
                }
            }
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

            SettingsDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Accounts")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(claudeAccountStore.accounts) { account in
                    AccountProfileRow(account: account) {
                        claudeAccountStore.removeAccount(id: account.id)
                        Task {
                            await dataManager.refreshAll()
                        }
                    }
                }
            }

            SettingsRowView(title: "New account") {
                TextField("Account name", text: $newClaudeAccountName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }

            SettingsRowView(title: "Config directory", detail: "Use a separate CLAUDE_CONFIG_DIR for each extra account.") {
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

    private var openAISection: some View {
        SettingsPanelSection(title: "OpenAI", logoKind: .codex, color: MeterBarTheme.codexAccent) {
            SettingsRowView(title: "Connection") {
                StatusPill(
                    title: authManager.isOpenAIAuthenticated ? "Connected" : "Not Connected",
                    isConnected: authManager.isOpenAIAuthenticated
                )
            }

            SettingsRowView(title: "Admin API Key", detail: "Required for platform usage APIs.") {
                SecureField("Admin API Key", text: $openaiAdminKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
            }

            SettingsRowView(title: "Actions") {
                HStack(spacing: 8) {
                    Button("Save") {
                        _ = authManager.setOpenAIAdminKey(openaiAdminKey)
                        openaiAdminKey = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(openaiAdminKey.isEmpty)

                    Button("Remove", role: .destructive) {
                        authManager.removeOpenAIAdminKey()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!authManager.isOpenAIAuthenticated)

                    Button("Help") {
                        showingOpenAIHelp = true
                    }
                    .buttonStyle(.bordered)
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
                SettingsNotice(text: "Reads Cursor IDE credentials from Cursor's local state database.", color: .secondary)
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
                SettingsNotice(text: "Enable Claude Code or OpenAI Codex to scan local token logs.", color: MeterBarTheme.warning)
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
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.claudeAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(account.configDirectory ?? "Default Claude CLI profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !account.isDefault {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shared admin-key help sheet. The Claude and OpenAI variants only differ by
/// copy and the console URL, so they share one layout.
private struct AdminKeyHelpView: View {
    @Environment(\.dismiss) var dismiss

    let title: String
    let intro: String
    let steps: [String]
    let note: String
    let consoleButtonTitle: String
    let consoleURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .bold()

            Text(intro)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
            }

            Divider()

            Text(note)
                .font(.caption)
                .foregroundStyle(MeterBarTheme.warning)

            HStack {
                Button(consoleButtonTitle) {
                    if let url = URL(string: consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct ClaudeHelpView: View {
    var body: some View {
        AdminKeyHelpView(
            title: "How to get Claude Admin API Key",
            intro: "The Usage API requires an Admin API key, which is different from a regular API key.",
            steps: [
                "Go to the Claude Console",
                "Navigate to Settings → Admin Keys",
                "Click 'Create Admin Key'",
                "Copy the key (starts with sk-ant-admin...)",
                "Paste it in the field above"
            ],
            note: "Note: You must be an organization admin to create Admin API keys. Individual accounts cannot access the Usage API.",
            consoleButtonTitle: "Open Claude Console",
            consoleURL: "https://console.anthropic.com/settings/admin-keys"
        )
    }
}

struct OpenAIHelpView: View {
    var body: some View {
        AdminKeyHelpView(
            title: "How to get OpenAI Admin API Key",
            intro: "The Usage API requires an Admin key from your organization settings.",
            steps: [
                "Go to OpenAI Platform",
                "Navigate to Settings → Organization → Admin Keys",
                "Click 'Create new admin key'",
                "Copy the key",
                "Paste it in the field above"
            ],
            note: "Note: You must be an organization owner or admin to create Admin keys.",
            consoleButtonTitle: "Open OpenAI Settings",
            consoleURL: "https://platform.openai.com/settings/organization/admin-keys"
        )
    }
}
