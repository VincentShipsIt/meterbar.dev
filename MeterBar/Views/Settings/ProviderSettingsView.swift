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
            AddProviderAccountSheet(
                providerName: ServiceType.claudeCode.shortName,
                logoKind: .claude,
                accent: MeterBarTheme.claudeAccent,
                subtitle: "Use a separate CLAUDE_CONFIG_DIR for this profile.",
                pathFieldLabel: "Config directory",
                pathPlaceholder: "Path"
            ) { name, configDirectory in
                addClaudeAccount(name: name, configDirectory: configDirectory)
                isAddingClaudeAccount = false
            }
        }
        .sheet(isPresented: $isAddingCodexAccount) {
            AddProviderAccountSheet(
                providerName: ServiceType.codexCli.shortName,
                logoKind: .codex,
                accent: MeterBarTheme.codexAccent,
                subtitle: "Use a separate CODEX_HOME containing its own auth.json.",
                pathFieldLabel: "CODEX_HOME",
                pathPlaceholder: "Codex home directory"
            ) { name, homeDirectory in
                codexAccountStore.addAccount(name: name, homeDirectory: homeDirectory)
                isAddingCodexAccount = false
                Task { await dataManager.refreshAll() }
            }
        }
        .sheet(isPresented: $isAddingGrokAccount) {
            AddProviderAccountSheet(
                providerName: ServiceType.grok.shortName,
                logoKind: .grok,
                accent: MeterBarTheme.grokAccent,
                subtitle: "Use a separate GROK_HOME containing its CLI-managed auth.json.",
                pathFieldLabel: "GROK_HOME",
                pathPlaceholder: "Grok home directory"
            ) { name, homeDirectory in
                grokAccountStore.addAccount(name: name, homeDirectory: homeDirectory)
                isAddingGrokAccount = false
                Task { await dataManager.refreshAll() }
            }
        }
        .task(id: codexDefaultAccount) {
            guard service == .codexCli, codexDefaultAccount.isEnabled else { return }
            let codexCliService = codexCliService
            let account = codexDefaultAccount
            await Task.detached(priority: .userInitiated) {
                codexCliService.checkAccess(account: account)
            }.value
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
    @StateObject private var menuBarAccountSelection = MenuBarAccountSelectionStore.shared
    @StateObject private var widgetPreferences = WidgetPreferencesStore.shared
    @StateObject private var sessionWakeSettings = SessionWakeSettingsStore.shared
    @StateObject private var parseHealthStore = ProviderParseHealthStore.shared

    @State private var isAddingClaudeAccount = false
    @State private var isAddingCodexAccount = false
    @State private var isAddingGrokAccount = false
    @State private var refreshingClaudeAccountIDs: Set<UUID> = []
    @State private var claudeReconnectError: String?
    @State private var openRouterKeyDraft = ""

    /// Same key ClaudeCodeLocalService reads. OAuth (`/api/oauth/usage`) is the
    /// primary Claude Code usage source and is on by default; turning this off
    /// forces the CLI-output fallback (which no longer renders headlessly).
    @AppStorage(StorageKeys.claudeCodeOAuthFallback)
    private var oauthFallbackEnabled = true

    private var providerSnapshots: [ProviderSnapshot] {
        ProviderSnapshotBuilder.snapshots(
            .live(
                stores: .init(
                    dataManager: dataManager,
                    claudeAccounts: claudeAccountStore.accounts,
                    codexAccounts: codexAccountStore.accounts,
                    grokAccounts: grokAccountStore.accounts,
                    enabledServices: providerVisibility.enabledServices,
                    claudeCodeService: claudeCodeService,
                    codexCliService: codexCliService,
                    cursorService: cursorService,
                    openRouterService: openRouterService,
                    grokService: grokService
                ),
                parseHealth: parseHealthStore.records
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
        CodexHomeDirectory.authFileDisplayPath(for: codexDefaultAccount)
    }

    private var codexDefaultAccount: CodexAccount {
        codexAccountStore.accounts.first(where: \.isDefault) ?? .defaultAccount
    }

    private var codexDefaultAuthenticationState: CodexAccountAuthenticationState {
        guard codexDefaultAccount.isEnabled else { return .disabled }
        return codexCliService.hasAccess ? .authenticated : .loginRequired
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
        DashboardTile(padding: .popover) {
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
                    Label("Refresh \(service.displayName)", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Refresh \(service.displayName)")
                .disabled(dataManager.isLoading)

                Toggle("", isOn: providerEnabledBinding(for: service))
                    .labelsHidden()
                    .meterBarSwitch()
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

            if let notice = facts.noticeText {
                SettingsNotice(text: notice, color: MeterBarTheme.warning)
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
                        // Blocking exhaustion matches the popover card: status +
                        // reset countdown only. A full red bar that reads
                        // "100% / Out of quota" just repeats the same fact.
                        if snapshot.hasExhaustedLimit {
                            ProviderBlockedUsageSummary(
                                snapshot: snapshot,
                                density: .settings,
                                showsTitle: true,
                                resetTimeFormat: .countdown
                            )
                        } else if snapshots.count > 1 {
                            ProviderTitle(
                                title: snapshot.title,
                                logoKind: snapshot.logoKind,
                                color: snapshot.accentColor,
                                font: .subheadline
                            )
                        }

                        if !snapshot.hasExhaustedLimit {
                            if snapshot.detailLimits.isEmpty {
                                EmptyStateCard(
                                    systemImage: "clock.badge.questionmark",
                                    title: "No quota windows",
                                    message: "This provider didn't report any limit windows."
                                )
                            } else {
                                ForEach(snapshot.detailLimits) { limit in
                                    LimitRow(
                                        limit: limit,
                                        accentColor: snapshot.accentColor,
                                        density: .regular
                                    )
                                }
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
                    ExtraUsageRow(
                        title: ServiceType.claudeCode.displayName,
                        status: claudeExtraUsageStatus,
                        manageURL: "https://claude.ai/settings"
                    )
                }
            }
        case .codexCli:
            SettingsPanelSection(title: "Credits", systemImage: "creditcard", color: MeterBarTheme.warning) {
                ExtraUsageRow(
                    title: ServiceType.codexCli.displayName,
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
                    title: ServiceType.grok.displayName,
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
                    StatusPill(
                        presentation: .claude(
                            defaultClaudeAuthState,
                            isEnabled: claudeAccountStore.defaultAccountIsEnabled
                        )
                    )

                    Button {
                        // This is an explicit user action, so it is the one
                        // Settings path allowed to request Keychain access.
                        Task {
                            await dataManager.refreshForExplicitAction(.manualRefresh)
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
                .meterBarSwitch()
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
                        ProviderAccountProfileRow(
                            accountName: account.name,
                            isDefault: account.isDefault,
                            isEnabled: account.isEnabled,
                            accent: MeterBarTheme.claudeAccent,
                            pathLabel: "Config directory",
                            pathPlaceholder: "Config directory",
                            resolvedPath: account.configDirectory
                                ?? ClaudeCodeAccount.defaultConfigDirectory(),
                            defaultPathHelp:
                                "Defaults to ~/.claude or $CLAUDE_CONFIG_DIR; clear the field to restore that default.",
                            statusPresentation: .claude(
                                claudeAuthState(for: account),
                                isEnabled: account.isEnabled
                            ),
                            canMoveUp: index > 0,
                            canMoveDown: index < claudeAccountStore.accounts.count - 1,
                            isRefreshing: refreshingClaudeAccountIDs.contains(account.id),
                            showsRefresh: true,
                            showsReconnect: true,
                            reconnectProviderName: ServiceType.claudeCode.shortName,
                            deleteMessage:
                                "MeterBar will stop tracking this CLAUDE_CONFIG_DIR. "
                                + "Files and Claude login data are not deleted.",
                            onEnabledChange: { isEnabled in
                                claudeAccountStore.setEnabled(isEnabled, for: account.id)
                                // Session Wake keeps Claude on its own reconcile
                                // path; the shared pass only owns the Codex one.
                                sessionWakeSettings.reconcileAccounts(
                                    available: claudeAccountStore.enabledAccounts.map(\.id)
                                )
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onSave: { name, configDirectory in
                                updateClaudeAccount(
                                    id: account.id,
                                    name: name,
                                    configDirectory: configDirectory
                                )
                            },
                            onRemove: {
                                claudeAccountStore.removeAccount(id: account.id)
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onRefresh: { refreshClaudeAccount(account) },
                            onReconnect: { reconnectClaudeAccount(account) },
                            onMoveUp: { moveClaudeAccount(at: index, down: false) },
                            onMoveDown: { moveClaudeAccount(at: index, down: true) }
                        )
                    }
                }
            }
        }
    }

    private var codexCliSection: some View {
        SettingsPanelSection(
            title: ServiceType.codexCli.displayName,
            logoKind: .codex,
            color: MeterBarTheme.codexAccent
        ) {
            SettingsRowView(
                title: "Default connection",
                detail: "Reads the OAuth session from \(codexAuthFileDisplayPath)."
            ) {
                HStack(spacing: 8) {
                    MeterBarChip(
                        codexDefaultAuthenticationState.title,
                        tint: codexDefaultAuthenticationState == .authenticated
                            ? MeterBarTheme.success
                            : .secondary,
                        style: .glass
                    )
                    .accessibilityLabel("Default Codex authentication status")
                    .accessibilityValue(codexDefaultAuthenticationState.accessibilityValue)

                    Button {
                        // checkAccess does disk I/O — run it off the main actor
                        // (a plain Task would inherit MainActor and block the UI).
                        Task {
                            let service = codexCliService
                            let account = codexDefaultAccount
                            await Task.detached(priority: .userInitiated) {
                                service.checkAccess(account: account)
                            }.value
                            await dataManager.refresh(service: .codexCli)
                        }
                    } label: {
                        Label(codexCliService.hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!codexDefaultAccount.isEnabled)
                    .accessibilityLabel("Check default Codex authentication")
                    .help(codexCliService.hasAccess ? "Refresh" : "Check again")
                }
            }

            if let subscriptionType = codexCliService.subscriptionType, codexCliService.hasAccess {
                SettingsRowView(title: "Plan") {
                    Text(subscriptionType.capitalized)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } else if codexDefaultAccount.isEnabled, !codexCliService.hasAccess {
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
                        CodexAccountSettingsRow(
                            account: account,
                            canDisable: codexAccountStore.canDisableAccount(id: account.id),
                            canRemove: codexAccountStore.canRemoveAccount(id: account.id),
                            canMoveUp: index > 0,
                            canMoveDown: index < codexAccountStore.accounts.count - 1,
                            onEnabledChange: { isEnabled in
                                guard codexAccountStore.setEnabled(isEnabled, for: account.id) == .updated else {
                                    return
                                }
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onSave: { name, homeDirectory in
                                codexAccountStore.updateAccount(
                                    id: account.id,
                                    name: name,
                                    homeDirectory: homeDirectory
                                )
                                Task { await dataManager.refreshAll() }
                            },
                            onRemove: {
                                guard codexAccountStore.removeAccount(id: account.id) == .updated else { return }
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onMoveUp: { moveCodexAccount(at: index, down: false) },
                            onMoveDown: { moveCodexAccount(at: index, down: true) }
                        )
                    }
                }
            }
        }
    }

    private var cursorSection: some View {
        SettingsPanelSection(
            title: ServiceType.cursor.displayName,
            logoKind: .cursor,
            color: MeterBarTheme.cursorAccent
        ) {
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
                                await dataManager.refreshForExplicitAction(.manualRefresh)
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
        SettingsPanelSection(
            title: ServiceType.openRouter.displayName,
            logoKind: .openRouter,
            color: MeterBarTheme.openRouterAccent
        ) {
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
                if openRouterService.hasAccess {
                    HStack(spacing: 8) {
                        StatusPill(title: "Configured", isConnected: true)
                        Button("Remove", role: .destructive) {
                            openRouterService.removeAPIKey()
                            Task { await dataManager.refresh(service: .openRouter) }
                        }
                        .buttonStyle(.bordered)

                        Button("Get Key") {
                            if let url = URL(string: "https://openrouter.ai/settings/keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    // The control column clamps at `controlMaxWidth` (300pt) with
                    // `.fixedSize`, so the field and both buttons cannot share
                    // one row — they crush into circles. The field leads and the
                    // actions sit under it, mirroring the other provider rows.
                    VStack(alignment: .trailing, spacing: 8) {
                        SecureField("sk-or-v1-...", text: $openRouterKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)

                        HStack(spacing: 8) {
                            Button("Save & Validate") {
                                guard openRouterService.saveAPIKey(openRouterKeyDraft) else { return }
                                openRouterKeyDraft = ""
                                providerVisibility.set(.openRouter, isEnabled: true)
                                Task { await dataManager.refresh(service: .openRouter) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Get Key") {
                                if let url = URL(string: "https://openrouter.ai/settings/keys") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
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
        let hasAccess = grokAccountStore.enabledAccounts.contains(where: grokService.canAccess(account:))
        return SettingsPanelSection(title: "Grok Build", logoKind: .grok, color: MeterBarTheme.grokAccent) {
            SettingsNotice(
                text: "MeterBar asks the official Grok CLI for billing data over ACP. "
                    + "The CLI owns authentication; MeterBar never reads or stores the cached token.",
                color: .secondary
            )

            SettingsRowView(title: "Connection") {
                HStack(spacing: 8) {
                    StatusPill(
                        title: hasAccess ? "Connected" : "Not Connected",
                        isConnected: hasAccess
                    )

                    Button {
                        Task {
                            let service = grokService
                            await Task.detached(priority: .userInitiated) {
                                service.checkAccess()
                            }.value
                            await dataManager.refresh(service: .grok)
                        }
                    } label: {
                        Label(hasAccess ? "Refresh" : "Check again", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help(hasAccess ? "Refresh" : "Check again")

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
            } else if !hasAccess {
                SettingsNotice(
                    text: "Install Grok Build and run `grok login`; no password or API key is entered in MeterBar.",
                    color: MeterBarTheme.warning
                )
            }

            if let error = grokService.firstError(for: grokAccountStore.enabledAccounts) {
                SettingsNotice(text: error.localizedDescription, color: MeterBarTheme.warning)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Grok Accounts")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        isAddingGrokAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                VStack(spacing: 0) {
                    ForEach(Array(grokAccountStore.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsDivider() }
                        ProviderAccountProfileRow(
                            accountName: account.name,
                            isDefault: account.isDefault,
                            isEnabled: account.isEnabled,
                            accent: MeterBarTheme.grokAccent,
                            pathLabel: "GROK_HOME",
                            pathPlaceholder: "Grok home directory",
                            resolvedPath: GrokHomeDirectory.path(for: account),
                            defaultPathHelp:
                                "Defaults to ~/.grok or $GROK_HOME; clear the field to restore that default.",
                            statusPresentation: ProviderAccountConnectionState
                                .from(
                                    isEnabled: account.isEnabled,
                                    isConnected: grokService.canAccess(account: account)
                                )
                                .statusPresentation,
                            canMoveUp: index > 0,
                            canMoveDown: index < grokAccountStore.accounts.count - 1,
                            deleteMessage:
                                "MeterBar will stop tracking this GROK_HOME. "
                                + "Files and Grok login data are not deleted.",
                            onEnabledChange: { isEnabled in
                                grokAccountStore.setEnabled(isEnabled, for: account.id)
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onSave: { name, homeDirectory in
                                grokAccountStore.updateAccount(
                                    id: account.id,
                                    name: name,
                                    homeDirectory: homeDirectory
                                )
                                Task { await dataManager.refreshAll() }
                            },
                            onRemove: {
                                grokAccountStore.removeAccount(id: account.id)
                                reconcileProviderAccountSelections()
                                Task { await dataManager.refreshAll() }
                            },
                            onMoveUp: { moveGrokAccount(at: index, down: false) },
                            onMoveDown: { moveGrokAccount(at: index, down: true) }
                        )
                    }
                }
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
                // Untracking any account-aware provider strands its selections
                // exactly the way disabling one of its accounts does, so this
                // runs for every provider rather than Codex alone.
                reconcileProviderAccountSelections()
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
            let codexDefaultAccount = codexDefaultAccount
            let cursor = cursorService
            let grok = grokService
            await Task.detached(priority: .userInitiated) {
                switch service {
                case .claudeCode:
                    claudeCode.checkAccess()
                case .codexCli:
                    codexCli.checkAccess(account: codexDefaultAccount)
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

    private func moveClaudeAccount(at index: Int, down: Bool) {
        moveAccount(at: index, down: down, count: claudeAccountStore.accounts.count) {
            claudeAccountStore.moveAccounts(fromOffsets: $0, toOffset: $1)
        }
    }

    private func moveCodexAccount(at index: Int, down: Bool) {
        moveAccount(at: index, down: down, count: codexAccountStore.accounts.count) {
            codexAccountStore.moveAccounts(fromOffsets: $0, toOffset: $1)
        }
    }

    private func moveGrokAccount(at index: Int, down: Bool) {
        moveAccount(at: index, down: down, count: grokAccountStore.accounts.count) {
            grokAccountStore.moveAccounts(fromOffsets: $0, toOffset: $1)
        }
    }

    private func moveAccount(
        at index: Int,
        down: Bool,
        count: Int,
        perform: (IndexSet, Int) -> Void
    ) {
        let destination = down ? index + 2 : index - 1
        guard index >= 0, index < count, destination >= 0, destination <= count else { return }
        perform(IndexSet(integer: index), destination)
    }

    private func reconnectClaudeAccount(_ account: ClaudeCodeAccount) {
        do {
            try ClaudeCodeReconnectService.openReconnectTerminal(for: account)
        } catch {
            claudeReconnectError = error.localizedDescription
        }
    }

    /// Keep every account-scoped consumer on the same enabled identity set after
    /// any provider disable, delete, or untrack. Session Wake clears and disarms
    /// rather than silently retargeting; menu-bar and widget preferences prune
    /// stale keys.
    ///
    /// The projection covers all three account-aware providers in one pass, so
    /// every call site gets the same result regardless of which provider was
    /// mutated — Claude and Grok call sites used to skip it, which left a
    /// disabled account holding one of the four status-item slots.
    private func reconcileProviderAccountSelections() {
        ProviderAccountSelectionReconciler.apply(
            ProviderAccountSelectionAvailability(
                claudeAccounts: claudeAccountStore.accounts,
                codexAccounts: codexAccountStore.accounts,
                grokAccounts: grokAccountStore.accounts,
                enabledServices: providerVisibility.enabledServices
            ),
            menuBarSelection: menuBarAccountSelection,
            widgetPreferences: widgetPreferences,
            sessionWakeSettings: sessionWakeSettings
        )
    }

    private var defaultClaudeAuthState: ClaudeCodeAuthState? {
        dataManager.claudeCodeAccountStates[ClaudeCodeAccount.defaultID] ?? claudeCodeService.authState
    }

    private func claudeAuthState(for account: ClaudeCodeAccount) -> ClaudeCodeAuthState? {
        dataManager.claudeCodeAccountStates[account.id]
            ?? (account.isDefault ? claudeCodeService.authState : nil)
    }

    private func refreshClaudeAccount(_ account: ClaudeCodeAccount) {
        guard refreshingClaudeAccountIDs.insert(account.id).inserted else { return }
        Task { @MainActor in
            defer { refreshingClaudeAccountIDs.remove(account.id) }
            await dataManager.refreshClaudeCodeAccount(id: account.id)
        }
    }
}
