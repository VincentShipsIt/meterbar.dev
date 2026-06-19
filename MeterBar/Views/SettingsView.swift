import SwiftUI
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
        Group {
            if embeddedInDashboard {
                settingsContent
            } else {
                ScrollView {
                    settingsContent
                        .padding(22)
                }
                .background(SettingsDesign.background)
            }
        }
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $showingClaudeHelp) {
            ClaudeHelpView()
        }
        .sheet(isPresented: $showingOpenAIHelp) {
            OpenAIHelpView()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            costTrackingSection
            refreshSection
            generalSection
        }
        .frame(maxWidth: 760, alignment: .leading)
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
                    .textFieldStyle(SettingsTextFieldStyle())
                    .frame(maxWidth: 330)
            }

            SettingsRowView(title: "Actions") {
                HStack(spacing: 8) {
                    Button("Save") {
                        _ = authManager.setClaudeAdminKey(claudeAdminKey)
                        claudeAdminKey = ""
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(claudeAdminKey.isEmpty)

                    Button("Remove") {
                        authManager.removeClaudeAdminKey()
                    }
                    .buttonStyle(SettingsButtonStyle(role: .destructive))
                    .disabled(!authManager.isClaudeAuthenticated)

                    Button("Help") {
                        showingClaudeHelp = true
                    }
                    .buttonStyle(SettingsButtonStyle())
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
                    .buttonStyle(SettingsButtonStyle())
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
                    .textFieldStyle(SettingsTextFieldStyle())
                    .frame(maxWidth: 220)
            }

            SettingsRowView(title: "Config directory", detail: "Use a separate CLAUDE_CONFIG_DIR for each extra account.") {
                HStack(spacing: 8) {
                    TextField("Path", text: $newClaudeConfigDirectory)
                        .textFieldStyle(SettingsTextFieldStyle())
                        .frame(maxWidth: 280)

                    Button("Choose") {
                        chooseClaudeConfigDirectory()
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }

            SettingsRowView(title: "Add profile") {
                Button("Add Account") {
                    addClaudeAccount()
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
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
                    .textFieldStyle(SettingsTextFieldStyle())
                    .frame(maxWidth: 330)
            }

            SettingsRowView(title: "Actions") {
                HStack(spacing: 8) {
                    Button("Save") {
                        _ = authManager.setOpenAIAdminKey(openaiAdminKey)
                        openaiAdminKey = ""
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(openaiAdminKey.isEmpty)

                    Button("Remove") {
                        authManager.removeOpenAIAdminKey()
                    }
                    .buttonStyle(SettingsButtonStyle(role: .destructive))
                    .disabled(!authManager.isOpenAIAuthenticated)

                    Button("Help") {
                        showingOpenAIHelp = true
                    }
                    .buttonStyle(SettingsButtonStyle())
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
                    .buttonStyle(SettingsButtonStyle())
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
                        if costTracker.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                            Text("Scanning...")
                        } else {
                            LucideIcon(.search, size: 13, lineWidth: 2.4)
                            Text("Scan 30 Days")
                        }
                    }
                }
                .buttonStyle(SettingsButtonStyle(prominent: true))
                .disabled(costTracker.isScanning || !canScanCosts)
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
                RefreshIconButton(title: "Refresh Now", help: "Refresh usage") {
                    Task {
                        await dataManager.refreshAll()
                    }
                }
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

private enum SettingsDesign {
    static let background = MeterBarTheme.graphiteBackground
    static let surface = MeterBarTheme.graphiteSurface
    static let row = Color.white.opacity(0.035)
    static let border = MeterBarTheme.border.opacity(0.82)
    static let borderStrong = MeterBarTheme.borderStrong
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let logoKind {
                    ProviderLogoView(kind: logoKind, size: 16, foregroundColor: color)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(color)
                        .frame(width: 16, height: 16)
                }

                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(SettingsDesign.row)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SettingsDesign.border, lineWidth: 1)
            }
        }
        .padding(14)
        .background(SettingsDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(SettingsDesign.border, lineWidth: 1)
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(maxWidth: 380, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SettingsDesign.border)
                .frame(height: 1)
                .padding(.leading, 12)
        }
    }
}

private struct SettingsNotice: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SettingsDesign.border)
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsDesign.borderStrong)
            .frame(height: 1)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }
}

private struct StatusPill: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? MeterBarTheme.success : Color.secondary)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background((isConnected ? MeterBarTheme.success : Color.secondary).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke((isConnected ? MeterBarTheme.success : Color.secondary).opacity(0.18), lineWidth: 1)
        }
    }
}

private struct AccountProfileRow: View {
    let account: ClaudeCodeAccount
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundColor(MeterBarTheme.claudeAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(account.configDirectory ?? "Default Claude CLI profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !account.isDefault {
                Button("Remove", action: onRemove)
                    .buttonStyle(SettingsButtonStyle(role: .destructive))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SettingsDesign.border)
                .frame(height: 1)
                .padding(.leading, 12)
        }
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    enum Role {
        case normal
        case destructive
    }

    @Environment(\.isEnabled) private var isEnabled

    var role: Role = .normal
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.70 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var textColor: Color {
        if prominent { return .white }
        switch role {
        case .normal:
            return .primary
        case .destructive:
            return MeterBarTheme.danger
        }
    }

    private var backgroundColor: Color {
        if prominent { return MeterBarTheme.appAccent }
        switch role {
        case .normal:
            return Color.white.opacity(0.06)
        case .destructive:
            return MeterBarTheme.danger.opacity(0.12)
        }
    }

    private var borderColor: Color {
        if prominent { return MeterBarTheme.appAccent.opacity(0.7) }
        switch role {
        case .normal:
            return SettingsDesign.borderStrong
        case .destructive:
            return MeterBarTheme.danger.opacity(0.22)
        }
    }
}

private struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.subheadline)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SettingsDesign.borderStrong, lineWidth: 1)
            }
    }
}

struct ClaudeHelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to get Claude Admin API Key")
                .font(.title2)
                .bold()

            Text("The Usage API requires an Admin API key, which is different from a regular API key.")
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Go to the Claude Console")
                Text("2. Navigate to Settings → Admin Keys")
                Text("3. Click 'Create Admin Key'")
                Text("4. Copy the key (starts with sk-ant-admin...)")
                Text("5. Paste it in the field above")
            }

            Divider()

            Text("Note: You must be an organization admin to create Admin API keys. Individual accounts cannot access the Usage API.")
                .font(.caption)
                .foregroundColor(MeterBarTheme.warning)

            HStack {
                Button("Open Claude Console") {
                    if let url = URL(string: "https://console.anthropic.com/settings/admin-keys") {
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

struct OpenAIHelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to get OpenAI Admin API Key")
                .font(.title2)
                .bold()

            Text("The Usage API requires an Admin key from your organization settings.")
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Go to OpenAI Platform")
                Text("2. Navigate to Settings → Organization → Admin Keys")
                Text("3. Click 'Create new admin key'")
                Text("4. Copy the key")
                Text("5. Paste it in the field above")
            }

            Divider()

            Text("Note: You must be an organization owner or admin to create Admin keys.")
                .font(.caption)
                .foregroundColor(MeterBarTheme.warning)

            HStack {
                Button("Open OpenAI Settings") {
                    if let url = URL(string: "https://platform.openai.com/settings/organization/admin-keys") {
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
