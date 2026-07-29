import MeterBarShared
import SwiftUI

/// One editable Grok profile. The default profile inherits `$GROK_HOME` (or
/// `~/.grok`) and cannot be removed; custom profiles own an explicit directory.
struct GrokAccountProfileRow: View {
    init(
        account: GrokAccount,
        isConnected: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) {
        self.account = account
        self.isConnected = isConnected
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onRemove = onRemove
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        _nameDraft = State(initialValue: account.name)
        _homeDirectoryDraft = State(initialValue: account.homeDirectory ?? "")
    }

    let account: GrokAccount
    let isConnected: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEnabledChange: (Bool) -> Void
    let onSave: (String, String?) -> Void
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.grokAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Account label", text: $nameDraft)
                        .settingsInput(width: 220)
                        .onSubmit(saveChanges)
                    Text(account.isDefault ? "Default" : "Profile")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.grokAccent)
                    StatusPill(title: isConnected ? "Connected" : "Not Connected", isConnected: isConnected)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Text("GROK_HOME")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 126, alignment: .leading)
                    if account.isDefault {
                        SettingsReadonlyField(text: GrokHomeDirectory.path(for: account))
                    } else {
                        TextField("Grok home directory", text: $homeDirectoryDraft)
                            .settingsInput(width: 280)
                            .onSubmit(saveChanges)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Toggle("Enabled", isOn: Binding(
                    get: { account.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(account.isEnabled ? "Disable account" : "Enable account")

                Button(action: onMoveUp) { Image(systemName: "arrow.up") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canMoveUp)
                    .help("Move account up")
                Button(action: onMoveDown) { Image(systemName: "arrow.down") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canMoveDown)
                    .help("Move account down")
                Button(action: saveChanges) { Image(systemName: "checkmark") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasChanges || !canSave)
                    .help("Save account changes")
                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete account")
                }
            }
            .fixedSize()
        }
        .padding(.vertical, MeterBarTheme.Spacing.md)
        .onChange(of: account) { _, updated in
            nameDraft = updated.name
            homeDirectoryDraft = updated.homeDirectory ?? ""
        }
    }

    @State private var nameDraft: String
    @State private var homeDirectoryDraft: String

    private var trimmedName: String { nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHomeDirectory: String {
        homeDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasChanges: Bool {
        trimmedName != account.name || (!account.isDefault && trimmedHomeDirectory != account.homeDirectory)
    }
    private var canSave: Bool { !trimmedName.isEmpty && (account.isDefault || !trimmedHomeDirectory.isEmpty) }

    private func saveChanges() {
        guard hasChanges, canSave else { return }
        onSave(trimmedName, account.isDefault ? nil : trimmedHomeDirectory)
    }
}
