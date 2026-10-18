import MeterBarShared
import SwiftUI

// Editor for the built-in routing policies. Changes stay in a draft until Save;
// the draft model (`RoutingPolicyEditor`) owns validation and persistence, so
// this file only lays the controls out.

/// Save, Cancel and Reset All, with the reason Save is unavailable.
struct RoutingPolicyEditorBar: View {
    let editor: RoutingPolicyEditor
    let saveError: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    let onResetAll: () -> Void

    @State private var confirmResetAll = false

    private var canSave: Bool {
        editor.isDirty && editor.saveBlockedReason == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
            HStack {
                Button("Reset All to Defaults", role: .destructive) { confirmResetAll = true }
                    .confirmationDialog(
                        "Reset every policy to its defaults?",
                        isPresented: $confirmResetAll
                    ) {
                        Button("Reset All", role: .destructive, action: onResetAll)
                    } message: {
                        Text("Nothing is saved until you press Save.")
                    }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            if let reason = saveError ?? editor.saveBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// One task's policy as editable controls.
struct RoutingPolicyEditorCard: View {
    let task: RoutingTaskID
    @Binding var editor: RoutingPolicyEditor
    let accounts: [RoutingPolicyEditor.AccountOption]

    @State private var confirmReset = false

    private static let providers = ServiceType.allCases.filter(\.supportsWorkloadRouting)
    private static let fallbackDeficit = 20

    private var policy: RoutingPolicy {
        editor.draft(task) ?? RoutingPolicyDefaults.policy(for: task)
    }

    var body: some View {
        DashboardCard(title: policy.name, trailing: editor.isCustomized(task) ? "Customized" : nil) {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                    providersRow
                    if policy.accountSelection != .automatic || !accounts.isEmpty {
                        accountRows
                    }
                    modelRows
                    quotaRows
                    rankingRows
                }
                ForEach(editor.problems.filter { $0.task == task }, id: \.message) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                    .disabled(!editor.isCustomized(task))
                    .confirmationDialog(
                        "Reset \(policy.name) to its defaults?",
                        isPresented: $confirmReset
                    ) {
                        Button("Reset", role: .destructive) { editor.reset(task) }
                    } message: {
                        Text("Nothing is saved until you press Save.")
                    }
            }
        }
    }

    // MARK: Rows

    private var providersRow: some View {
        GridRow {
            label("Providers")
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                Picker("Providers", selection: binding(\.providerScope)) {
                    ForEach(RoutingProviderScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                help(policy.providerScope.help)
                ForEach(orderedProviders, id: \.self, content: providerRow)
            }
        }
    }

    @ViewBuilder private var accountRows: some View {
        GridRow {
            label("Accounts")
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                Picker("Accounts", selection: binding(\.accountSelection)) {
                    ForEach(RoutingAccountSelection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                help(policy.accountSelection.help)
                if policy.accountSelection != .automatic {
                    if accounts.isEmpty {
                        help("No connected accounts yet. Connect a provider to choose one.")
                    }
                    ForEach(accounts) { account in
                        Toggle(
                            "\(account.ref.provider.displayName) · \(account.label)",
                            isOn: accountBinding(account.ref)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private var modelRows: some View {
        GridRow {
            label("Model tier")
            Picker("Model tier", selection: binding(\.modelTier)) {
                ForEach(RoutingModelTier.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        GridRow {
            label("Model names")
            DisclosureGroup("Optional per provider") {
                VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.sm) {
                    help("Leave blank to recommend the tier only. Names are not checked against the provider.")
                    ForEach(Self.providers, id: \.self) { provider in
                        TextField(
                            provider.displayName,
                            text: aliasBinding(provider),
                            prompt: Text("Provider default")
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, MeterBarTheme.Spacing.xs)
            }
        }
    }

    @ViewBuilder private var quotaRows: some View {
        GridRow {
            label("Minimum remaining")
            Stepper(value: binding(\.minimumRemainingPercent), in: 0...100, step: 5) {
                Text("\(policy.minimumRemainingPercent)%")
            }
        }
        GridRow {
            label("Pacing")
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
                Toggle("Skip routes that are far behind pace", isOn: deficitEnabledBinding)
                if let limit = policy.maximumDeficitPercent {
                    Stepper(value: deficitBinding, in: 0...100, step: 5) {
                        Text("Skip when more than \(limit)% behind")
                    }
                }
            }
        }
        GridRow {
            label("Estimated quota")
            Toggle("Allow routes whose quota is estimated", isOn: binding(\.allowsEstimatedQuota))
        }
    }

    @ViewBuilder private var rankingRows: some View {
        GridRow {
            label("Cost")
            VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.xs) {
                Picker("Cost", selection: binding(\.costPreference)) {
                    ForEach(RoutingCostPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                help(policy.costPreference.help)
            }
        }
        GridRow {
            label("Fallbacks")
            HStack {
                Stepper(value: binding(\.maximumFallbacks), in: 0...RoutingPolicy.maximumFallbackCount) {
                    Text(policy.maximumFallbacks == 0 ? "None" : "Up to \(policy.maximumFallbacks)")
                }
                Picker("Fallback order", selection: binding(\.fallbackOrder)) {
                    ForEach(RoutingFallbackOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(policy.maximumFallbacks == 0)
            }
        }
    }

    private func providerRow(_ provider: ServiceType) -> some View {
        let rank = policy.providerPreference.firstIndex(of: provider)
        return HStack(spacing: MeterBarTheme.Spacing.sm) {
            Toggle(provider.displayName, isOn: preferredBinding(provider))
            Spacer()
            if let rank {
                Text("#\(rank + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    editor.moveProvider(provider, up: true, in: task)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(rank == 0)
                .accessibilityLabel("Move \(provider.displayName) up")
                Button {
                    editor.moveProvider(provider, up: false, in: task)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(rank == policy.providerPreference.count - 1)
                .accessibilityLabel("Move \(provider.displayName) down")
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Helpers

    /// Chosen providers in preference order, then the rest.
    private var orderedProviders: [ServiceType] {
        let chosen = policy.providerPreference.filter(\.supportsWorkloadRouting)
        return chosen + Self.providers.filter { !chosen.contains($0) }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(width: 140, alignment: .leading)
    }

    private func help(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RoutingPolicy, Value>) -> Binding<Value> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { value in editor.edit(task) { $0[keyPath: keyPath] = value } }
        )
    }

    private func preferredBinding(_ provider: ServiceType) -> Binding<Bool> {
        Binding(
            get: { policy.providerPreference.contains(provider) },
            set: { editor.setPreferred(provider, included: $0, in: task) }
        )
    }

    private func accountBinding(_ account: RoutingAccountRef) -> Binding<Bool> {
        Binding(
            get: { policy.accounts.contains(account) },
            set: { editor.setAccount(account, included: $0, in: task) }
        )
    }

    private func aliasBinding(_ provider: ServiceType) -> Binding<String> {
        Binding(
            get: { policy.modelAliases[provider] ?? "" },
            set: { editor.setAlias($0, for: provider, in: task) }
        )
    }

    private var deficitEnabledBinding: Binding<Bool> {
        Binding(
            get: { policy.maximumDeficitPercent != nil },
            set: { enabled in
                editor.edit(task) { $0.maximumDeficitPercent = enabled ? Self.fallbackDeficit : nil }
            }
        )
    }

    private var deficitBinding: Binding<Int> {
        Binding(
            get: { policy.maximumDeficitPercent ?? Self.fallbackDeficit },
            set: { value in editor.edit(task) { $0.maximumDeficitPercent = value } }
        )
    }
}
