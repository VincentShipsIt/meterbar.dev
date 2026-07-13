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
            one at a time. It only runs while MeterBar is open.
            """)
        }
    }

    // MARK: - Layout

    private var layout: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var sections: some View {
        accountSection
        switchSection
        previewSection
        limitsSection
        permissionSection
        notificationSection
    }

    // MARK: - Sections

    private var switchSection: some View {
        Section("Session Wake") {
            Toggle("Session Wake", isOn: onBinding)
                .disabled(!store.canTurnOn && !store.isOn)
                .toggleStyle(.switch)
            if store.wakeAccountID == nil {
                Text("Choose a wake account above to enable Session Wake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Status", value: status.label(isOn: store.isOn).title)
        }
    }

    private var accountSection: some View {
        Section("Wake account") {
            Picker("Account", selection: accountBinding) {
                Text("None selected").tag(UUID?.none)
                ForEach(accounts.enabledAccounts) { account in
                    Text(account.name).tag(UUID?.some(account.id))
                }
            }
            if store.isOn {
                Text("Changing the wake account turns Session Wake off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Button("Preview resumable sessions") {
                Task { await status.preview(configDirectory: selectedConfigDirectory) }
            }
            .disabled(status.isPreviewing)
            LabeledContent("Eligible", value: "\(status.eligibleCount)")
            ForEach(Array(status.skipSummary.keys), id: \.self) { reason in
                LabeledContent(reason.rawValue, value: "\(status.skipSummary[reason] ?? 0)")
                    .font(.footnote)
            }
            if let summary = status.lastSummary {
                let detail = "\(summary.resumed) resumed · \(summary.failed) failed · \(summary.skipped) skipped"
                LabeledContent("Last run", value: detail)
                    .font(.footnote)
            }
        }
    }

    private var limitsSection: some View {
        Section("Limits") {
            Stepper(
                "Max sessions per run: \(store.maxSessionsPerRun)",
                value: binding(store.maxSessionsPerRun, store.setMaxSessionsPerRun),
                in: WakeBounds.sessionsRange
            )
            Stepper(
                "Max turns per session: \(store.maxTurns)",
                value: binding(store.maxTurns, store.setMaxTurns),
                in: WakeBounds.maxTurnsRange
            )
            TextField("Resume prompt", text: $store.prompt)
        }
    }

    private var permissionSection: some View {
        Section("Permissions") {
            Picker("Permission mode", selection: binding(store.permissionMode, store.setPermissionMode)) {
                Text("Safe").tag(WakePermissionMode.safe)
                Text("Bypass").tag(WakePermissionMode.bypass)
            }
            if store.permissionMode == .bypass {
                Toggle(
                    "I acknowledge bypassing permission prompts is risky",
                    isOn: binding(store.bypassAcknowledged, store.setBypassAcknowledged)
                )
                .font(.callout)
            }
        }
    }

    private var notificationSection: some View {
        Section("Notifications") {
            Toggle("Notify when a run completes", isOn: $store.notifyOnCompletion)
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
