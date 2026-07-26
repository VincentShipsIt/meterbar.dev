import AppKit
import MeterBarShared
import SwiftUI

/// One provider's settings page: header, overview, usage bars, and that
/// provider's connection settings. The two account sheets and the
/// reconnect-failure alert live here because they're driven entirely by controls
/// on this page.
///
/// Which provider is showing is the *sidebar's* selection — this view used to
/// own a second, horizontal segmented picker over the same choice, which meant
/// two navigation layers for one hierarchy and a control that widened with every
/// provider MeterBar added.
///
/// The overview facts (source/status/plan/error) are derived once via
/// `ProviderSettingsFacts` rather than through the old per-helper `switch`
/// ladder.
struct ProviderSettingsView: View {
    // MARK: Internal

    let service: ServiceType

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSettingsPane(for: service)
        }
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
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var fableSessionTracker = ClaudeFableSessionTracker.shared

    @State private var isAddingClaudeAccount = false
    @State private var isAddingCodexAccount = false
    @State private var claudeReconnectError: String?
    @State private var openRouterKeyDraft = ""

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
                fableSessions: fableSessionTracker.sessions,
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

    private var claudeExtraUsageStatus: ExtraUsageStatus? {
        ExtraUsageDisplayPolicy.visibleStatus(
            for: .claudeCode,
            status: dataManager.metrics[.claudeCode]?.extraUsage
        )
    }

    private var codexAuthFileDisplayPath: String {
        CodexHomeDirectory.authFileDisplayPath()
    }

    // MARK: - Provider pane

    private func providerSettingsPane(for service: ServiceType) -> some View {
        let facts = facts(for: service)
        return VStack(alignment: .leading, spacing: 14) {
            providerHeader(for: service, facts: facts)
            providerInfoSection(facts: facts)
            providerUsageSection(for: service)
            providerSpecificSettings(for: service)
        }
    }

    private func providerHeader(for service: ServiceType, facts: ProviderSettingsFacts) -> some View {
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
                    Text(facts.sourceText)
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

    private func providerInfoSection(facts: ProviderSettingsFacts) -> some View {
        SettingsPanelSection(
            title: "Overview",
            logoKind: .forService(facts.service),
            color: MeterBarTheme.accent(for: facts.service)
        ) {
            SettingsInfoRow(label: "Source", value: facts.sourceText)
            SettingsInfoRow(label: "Updated", value: facts.updatedText)
            SettingsInfoRow(label: "Status", value: facts.statusText)

            if let plan = facts.planText {
                SettingsInfoRow(label: "Plan", value: plan)
            }

            if let error = facts.errorText {
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
            FableSessionHistoryView(
                sessions: fableSessionTracker.sessions,
                diagnostics: fableSessionTracker.diagnostics
            )
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
                    ExtraUsageRow(
                        title: "Claude Code",
                        status: claudeExtraUsageStatus,
                        manageURL: "https://claude.ai/settings"
                    )
                }
            }
        case .codexCli:
            SettingsPanelSection(title: "Credits", systemImage: "creditcard", color: MeterBarTheme.warning) {
                ExtraUsageRow(
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
                ExtraUsageRow(
                    title: "Grok",
                    status: dataManager.metrics[.grok]?.extraUsage,
                    manageURL: "https://grok.com/?_s=usage"
                )
            }
        }
    }

    // MARK: - Provider-specific connection sections

    private var claudeCodeSection: some View {
        SettingsPanelSection(title: "Claude Code (Pro/Max)", logoKind: .claude, color: MeterBarTheme.claudeAccent) {
            SettingsRowView(title: "CLI status") {
                HStack(spacing: 8) {
                    StatusPill(title: claudeCodeService.authState.statusText, isConnected: claudeCodeService.hasAccess)

                    Button {
                        // This is an explicit user action, so it is the one
                        // Settings path allowed to request Keychain access.
                        Task {
                            await dataManager.refreshAll(trigger: .userInitiated)
                        }
                    } label: {
                        Label(claudeCodeService.hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help(claudeCodeService.hasAccess ? "Refresh" : "Check again")
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
                                MenuBarAccountSelectionStore.shared.forget(
                                    MenuBarAccountKey.make(service: .claudeCode, accountID: account.id)
                                )
                                Task { await dataManager.refreshAll() }
                            }
                        )
                    }
                }
            }
        }
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

                    Button {
                        // checkAccess does disk I/O — run it off the main actor
                        // (a plain Task would inherit MainActor and block the UI).
                        Task {
                            let service = codexCliService
                            await Task.detached(priority: .userInitiated) { service.checkAccess() }.value
                            await dataManager.refresh(service: .codexCli)
                        }
                    } label: {
                        Label(codexCliService.hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help(codexCliService.hasAccess ? "Refresh" : "Check again")
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
                                MenuBarAccountSelectionStore.shared.forget(
                                    MenuBarAccountKey.make(service: .codexCli, accountID: account.id)
                                )
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

                    Button {
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
                    } label: {
                        Label(cursorService.hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help(cursorService.hasAccess ? "Refresh" : "Check again")
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

                    Button {
                        Task {
                            let service = grokService
                            await Task.detached(priority: .userInitiated) {
                                service.checkAccess()
                            }.value
                            if grokService.hasAccess {
                                await dataManager.refresh(service: .grok)
                            }
                        }
                    } label: {
                        Label(grokService.hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help(grokService.hasAccess ? "Refresh" : "Check again")

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

    // MARK: - Derivation

    /// Shared with the settings sidebar's health dot, so a provider's row and its
    /// page can never disagree about whether it's connected.
    private func facts(for service: ServiceType) -> ProviderSettingsFacts {
        ProviderSettingsFacts.live(for: service, snapshots: providerSnapshots)
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

    // MARK: - Account mutations

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
