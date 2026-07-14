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
    @State private var showingFirstRunConfirmation = false

    @MainActor
    init(
        store: SessionWakeSettingsStore? = nil,
        status: SessionWakeStatus? = nil,
        accounts: ClaudeCodeAccountStore? = nil
    ) {
        self.store = store ?? .shared
        self.status = status ?? .shared
        self.accounts = accounts ?? .shared
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
            limit resets, automatically resumes your blocked Claude Code sessions \
            one at a time. The background watcher keeps running after MeterBar quits.
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
        notificationSection
    }

    // MARK: - Sections

    private var switchSection: some View {
        SettingsPanelSection(title: "Session Wake", systemImage: "moon.zzz", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Session Wake",
                detail: store.wakeAccountID == nil
                    ? "Choose a wake account above to enable Session Wake."
                    : "Automatically resume blocked Claude Code sessions after a limit resets."
            ) {
                Toggle("", isOn: onBinding)
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
            SettingsRowView(title: "Account") {
                Picker("", selection: accountBinding) {
                    Text("None selected").tag(UUID?.none)
                    ForEach(accounts.enabledAccounts) { account in
                        Text(account.name).tag(UUID?.some(account.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            if store.isOn {
                SettingsNotice(text: "Changing the wake account turns Session Wake off.", color: .secondary)
            }
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
                    "",
                    value: binding(store.maxSessionsPerRun, store.setMaxSessionsPerRun),
                    in: WakeBounds.sessionsRange
                )
                .labelsHidden()
            }

            SettingsRowView(title: "Max turns per session", detail: "\(store.maxTurns)") {
                Stepper(
                    "",
                    value: binding(store.maxTurns, store.setMaxTurns),
                    in: WakeBounds.maxTurnsRange
                )
                .labelsHidden()
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
                Picker("", selection: binding(store.permissionMode, store.setPermissionMode)) {
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
                    Toggle("", isOn: binding(store.bypassAcknowledged, store.setBypassAcknowledged))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var notificationSection: some View {
        SettingsPanelSection(title: "Notifications", systemImage: "bell", color: MeterBarTheme.appAccent) {
            SettingsRowView(
                title: "Notify when a run completes",
                detail: "Post a notification after Session Wake finishes resuming sessions."
            ) {
                Toggle("", isOn: $store.notifyOnCompletion)
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

    private var accountBinding: Binding<UUID?> {
        Binding(get: { store.wakeAccountID }, set: { store.setWakeAccountID($0) })
    }

    private var selectedConfigDirectory: String? {
        accounts.enabledAccounts.first(where: { $0.id == store.wakeAccountID })?.configDirectory
    }

    private func binding<Value>(_ value: Value, _ setter: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { setter($0) })
    }
}
