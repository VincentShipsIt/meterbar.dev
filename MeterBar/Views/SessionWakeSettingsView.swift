import SwiftUI

/// Settings → Automation pane for Session Wake.
///
/// The view is intentionally thin: it renders shared store/status state and
/// routes every mutation back through `SessionWakeSettingsStore`, which owns the
/// safety toggle rules. No automation logic lives here.
struct SessionWakeSettingsView: View {
    @ObservedObject private var store: SessionWakeSettingsStore
    @ObservedObject private var status: SessionWakeStatus
    @ObservedObject private var accounts: ClaudeCodeAccountStore

    init(
        store: SessionWakeSettingsStore = .shared,
        status: SessionWakeStatus = .shared,
        accounts: ClaudeCodeAccountStore = .shared
    ) {
        self.store = store
        self.status = status
        self.accounts = accounts
    }

    var body: some View {
        Form {
            enablementSection
            accountSection
            watcherSection
            previewSection
            limitsSection
            permissionSection
            notificationSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var enablementSection: some View {
        Section("Session Wake") {
            Toggle("Enable Session Wake", isOn: binding(store.featureEnabled, store.setFeatureEnabled))
            if store.featureEnabled {
                Toggle(
                    "I understand MeterBar will resume blocked sessions automatically",
                    isOn: binding(store.firstEnableAcknowledged, store.setFirstEnableAcknowledged)
                )
                .font(.callout)
            }
            LabeledContent("Status", value: status.label(featureEnabled: store.featureEnabled).title)
        }
    }

    private var accountSection: some View {
        Section("Wake account") {
            Picker("Account", selection: accountBinding) {
                Text("None selected").tag(UUID?.none)
                ForEach(accounts.accounts) { account in
                    Text(account.name).tag(UUID?.some(account.id))
                }
            }
            .disabled(!store.featureEnabled)
        }
    }

    private var watcherSection: some View {
        Section("Watcher") {
            Toggle("Watcher active", isOn: binding(store.watcherArmed, store.setWatcherArmed))
                .disabled(!store.canArmWatcher || store.wakeAccountID == nil)
            if !store.canArmWatcher && store.featureEnabled {
                Text("Acknowledge the safety note above to arm the watcher.")
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

    private var accountBinding: Binding<UUID?> {
        Binding(get: { store.wakeAccountID }, set: { store.setWakeAccountID($0) })
    }

    private var selectedConfigDirectory: String? {
        accounts.accounts.first(where: { $0.id == store.wakeAccountID })?.configDirectory
    }

    private func binding<Value>(_ value: Value, _ setter: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { setter($0) })
    }
}
