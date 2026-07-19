import SwiftUI

/// Settings → Automation pane for Session Wake.
///
/// A single ON/OFF switch drives the watcher; the first time it is turned on a
/// one-time confirmation explains what it does. The view is thin: every
/// mutation routes back through `SessionWakeSettingsStore`, which owns the
/// safety rules, and the live watcher is run by `SessionWakeController`.
struct SessionWakeSettingsView: View {
    @ObservedObject private var store: SessionWakeSettingsStore
    @ObservedObject private var status: SessionWakeStatus
    @ObservedObject private var accounts: ClaudeCodeAccountStore
    @ObservedObject private var codexAccounts: CodexAccountStore
    @State private var showingFirstRunConfirmation = false
    @State private var isTestingHook = false
    @State private var hookTestMessage: String?

    @MainActor
    init(
        store: SessionWakeSettingsStore? = nil,
        status: SessionWakeStatus? = nil,
        accounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil
    ) {
        self.store = store ?? .shared
        self.status = status ?? .shared
        self.accounts = accounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
    }

    var body: some View {
        layout
        .confirmationDialog(
            "Turn on Session Wake?",
            isPresented: $showingFirstRunConfirmation,
            titleVisibility: .visible
        ) {
            Button("Turn On") { store.acknowledgeFirstRunAndTurnOn() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            While on, MeterBar watches this account's usage limits and, after a \
            limit resets, automatically resumes your blocked \
            \(store.wakeProvider.displayName) sessions one at a time. The \
            background watcher keeps running after MeterBar quits.
            """)
        }
    }

    // MARK: - Layout

    /// Matches the card style used by every other Settings tab
    /// (`SettingsPanelSection` + `SettingsRowView`) instead of a grouped `Form`,
    /// so the Automation tab is visually consistent with the rest.
    @ViewBuilder private var layout: some View {
        accountSection
        switchSection
        previewSection
        limitsSection
        permissionSection
        eventHookSection
        notificationSection
    }

    // MARK: - Sections

    private var switchSection: some View {
        SettingsPanelSection(title: "Session Wake", systemImage: "moon.zzz", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Session Wake",
                detail: store.activeAccountID == nil
                    ? "Choose a wake account above to enable Session Wake."
                    : "Automatically resume blocked \(store.wakeProvider.displayName) sessions after a limit resets."
            ) {
                Toggle("Session Wake", isOn: onBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!store.canTurnOn && !store.isOn)
            }

            SettingsRowView(title: "Status") {
                Text(status.label(isOn: store.isOn).title)
                    .foregroundStyle(.secondary)
            }

            SettingsRowView(
                title: "Execution",
                detail: status.backgroundExecution.detail
            ) {
                if status.backgroundExecution == .requiresApproval {
                    Button("Open Login Items") {
                        SMAppServiceSessionWakeAgent.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text(status.backgroundExecution.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accountSection: some View {
        SettingsPanelSection(title: "Wake account", systemImage: "person.crop.circle", color: MeterBarTheme.appAccent) {
            SettingsRowView(title: "Provider") {
                Picker("", selection: providerBinding) {
                    ForEach(WakeProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            SettingsRowView(title: "Account") {
                Picker("Wake account", selection: accountBinding) {
                    Text("None selected").tag(UUID?.none)
                    ForEach(providerAccounts) { account in
                        Text(account.name).tag(UUID?.some(account.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            if store.isOn {
                SettingsNotice(
                    text: "Changing the provider or wake account turns Session Wake off.",
                    color: .secondary
                )
            }
        }
    }

    /// Name + id pairs for the currently selected provider's enabled accounts.
    private var providerAccounts: [AccountChoice] {
        switch store.wakeProvider {
        case .claude:
            return accounts.enabledAccounts.map { AccountChoice(id: $0.id, name: $0.name) }
        case .codex:
            return codexAccounts.enabledAccounts.map { AccountChoice(id: $0.id, name: $0.name) }
        }
    }

    private var previewSection: some View {
        SettingsPanelSection(title: "Preview", systemImage: "eye", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Resumable sessions",
                detail: "Check how many blocked sessions would resume on the next wake."
            ) {
                Button("Preview") {
                    Task { await status.preview(configDirectory: selectedConfigDirectory) }
                }
                .buttonStyle(.bordered)
                .disabled(status.isPreviewing)
            }

            SettingsRowView(title: "Eligible") {
                Text("\(status.eligibleCount)")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(status.skipSummary.keys), id: \.self) { reason in
                SettingsRowView(title: reason.rawValue) {
                    Text("\(status.skipSummary[reason] ?? 0)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = status.lastSummary {
                SettingsRowView(title: "Last run") {
                    Text("\(summary.resumed) resumed · \(summary.failed) failed · \(summary.skipped) skipped")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var limitsSection: some View {
        SettingsPanelSection(title: "Limits", systemImage: "slider.horizontal.3", color: MeterBarTheme.appAccent) {
            SettingsRowView(title: "Max sessions per run", detail: "\(store.maxSessionsPerRun)") {
                Stepper(
                    "Max sessions per run",
                    value: binding(store.maxSessionsPerRun, store.setMaxSessionsPerRun),
                    in: WakeBounds.sessionsRange
                )
                .labelsHidden()
                .accessibilityValue("\(store.maxSessionsPerRun)")
            }

            SettingsRowView(title: "Max turns per session", detail: "\(store.maxTurns)") {
                Stepper(
                    "Max turns per session",
                    value: binding(store.maxTurns, store.setMaxTurns),
                    in: WakeBounds.maxTurnsRange
                )
                .labelsHidden()
                .accessibilityValue("\(store.maxTurns)")
            }

            SettingsRowView(title: "Resume prompt") {
                TextField("continue", text: $store.prompt)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        }
    }

    private var permissionSection: some View {
        SettingsPanelSection(title: "Permissions", systemImage: "lock.shield", color: MeterBarTheme.appAccent) {
            SettingsRowView(title: "Permission mode") {
                Picker("Permission mode", selection: binding(store.permissionMode, store.setPermissionMode)) {
                    Text("Safe").tag(WakePermissionMode.safe)
                    Text("Bypass").tag(WakePermissionMode.bypass)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }

            if store.permissionMode == .bypass {
                SettingsRowView(
                    title: "Acknowledge risk",
                    detail: "Bypassing permission prompts lets resumed sessions run without confirmation."
                ) {
                    Toggle("Acknowledge risk", isOn: binding(store.bypassAcknowledged, store.setBypassAcknowledged))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var eventHookSection: some View {
        SettingsPanelSection(title: "Event hooks", systemImage: "terminal", color: MeterBarTheme.appAccent) {
            SettingsNotice(
                text: "Optional local commands run directly without a shell. " +
                    "Each argument below is one literal argv entry.",
                color: .secondary
            )

            SettingsRowView(
                title: "Executable",
                detail: "Use an absolute path to an executable file."
            ) {
                TextField("/usr/local/bin/my-hook", text: hookExecutableBinding)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(store.eventHookConfiguration.arguments.indices, id: \.self) { index in
                SettingsRowView(title: "Argument \(index + 1)") {
                    HStack(spacing: 6) {
                        TextField("Literal argument", text: hookArgumentBinding(at: index))
                            .textFieldStyle(.roundedBorder)

                        Button {
                            store.removeHookArgument(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove argument \(index + 1)")
                    }
                }
            }

            SettingsRowView(
                title: "Arguments",
                detail: "Add one field for every argv entry, including flags and values."
            ) {
                Button("Add Argument") {
                    store.addHookArgument()
                }
                .buttonStyle(.bordered)
            }

            commandPreview

            ForEach(WakeEventHookEvent.allCases, id: \.self) { event in
                SettingsRowView(title: event.displayName) {
                    Toggle(event.displayName, isOn: hookEventBinding(event))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!store.eventHookConfiguration.isConfigured)
                }
            }

            SettingsRowView(
                title: "Test hook",
                detail: "Runs once with METERBAR_WAKE_EVENT=test and the same literal arguments."
            ) {
                Button(isTestingHook ? "Running…" : "Run Test") {
                    testHook()
                }
                .buttonStyle(.bordered)
                .disabled(!store.eventHookConfiguration.isConfigured || isTestingHook)
            }

            if let hookTestMessage {
                SettingsNotice(
                    text: hookTestMessage,
                    color: hookTestColor
                )
            }
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Exact command")
                .font(.caption)
                .fontWeight(.semibold)
            Text("executable: \(store.eventHookConfiguration.normalizedExecutablePath)")
            ForEach(Array(store.eventHookConfiguration.arguments.enumerated()), id: \.offset) { index, argument in
                Text("argv[\(index)]: \(argument)")
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var hookTestColor: Color {
        hookTestMessage == "Hook completed successfully." ? MeterBarTheme.success : MeterBarTheme.warning
    }

    private var notificationSection: some View {
        SettingsPanelSection(title: "Notifications", systemImage: "bell", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Notify when a run completes",
                detail: "Post a notification after Session Wake finishes resuming sessions."
            ) {
                Toggle("Notify when a run completes", isOn: $store.notifyOnCompletion)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Bindings

    /// The single toggle. Turning on the first time defers to the confirmation;
    /// once acknowledged it toggles directly.
    private var onBinding: Binding<Bool> {
        Binding(
            get: { store.isOn },
            set: { newValue in
                if newValue {
                    if store.needsFirstRunConfirmation {
                        showingFirstRunConfirmation = true
                    } else {
                        store.setOn(true)
                    }
                } else {
                    store.setOn(false)
                }
            }
        )
    }

    private var providerBinding: Binding<WakeProvider> {
        Binding(get: { store.wakeProvider }, set: { store.setWakeProvider($0) })
    }

    /// Routes the account picker to the active provider's selection so each
    /// provider keeps its own explicitly chosen account.
    private var accountBinding: Binding<UUID?> {
        Binding(
            get: { store.activeAccountID },
            set: { newValue in
                switch store.wakeProvider {
                case .claude: store.setWakeAccountID(newValue)
                case .codex: store.setWakeCodexAccountID(newValue)
                }
            }
        )
    }

    private var hookExecutableBinding: Binding<String> {
        Binding(
            get: { store.eventHookConfiguration.executablePath },
            set: { store.setHookExecutablePath($0) }
        )
    }

    private func hookArgumentBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard store.eventHookConfiguration.arguments.indices.contains(index) else { return "" }
                return store.eventHookConfiguration.arguments[index]
            },
            set: { store.setHookArgument($0, at: index) }
        )
    }

    private func hookEventBinding(_ event: WakeEventHookEvent) -> Binding<Bool> {
        Binding(
            get: { store.eventHookConfiguration.enabledEvents.contains(event) },
            set: { store.setHookEnabled($0, for: event) }
        )
    }

    /// The Claude config directory to preview against. Preview uses Claude
    /// session discovery, so it is only meaningful for the Claude provider.
    private var selectedConfigDirectory: String? {
        guard store.wakeProvider == .claude else { return nil }
        return accounts.enabledAccounts.first(where: { $0.id == store.wakeAccountID })?.configDirectory
    }

    private func binding<Value>(_ value: Value, _ setter: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { setter($0) })
    }

    private func testHook() {
        let configuration = store.eventHookConfiguration
        isTestingHook = true
        hookTestMessage = nil
        Task {
            let result = await WakeEventHookRunner().run(
                configuration: configuration,
                context: .test
            )
            hookTestMessage = result.userMessage
            isTestingHook = false
        }
    }
}

/// A provider-agnostic account row for the wake account picker, so the picker
/// can list either `ClaudeCodeAccount`s or `CodexAccount`s uniformly.
private struct AccountChoice: Identifiable {
    let id: UUID
    let name: String
}
