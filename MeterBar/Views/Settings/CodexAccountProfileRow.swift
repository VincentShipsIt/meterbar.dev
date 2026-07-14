import MeterBarShared
import SwiftUI

/// One editable Codex account row (name + CODEX_HOME + save / delete).
/// Extracted verbatim from the SettingsView monolith. The default profile is
/// read-only for its home directory and cannot be removed.
struct CodexAccountProfileRow: View {
    // MARK: Lifecycle

    init(
        account: CodexAccount,
        isConnected: Bool,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.isConnected = isConnected
        self.onSave = onSave
        self.onRemove = onRemove
        _nameDraft = State(initialValue: account.name)
        _homeDirectoryDraft = State(initialValue: account.homeDirectory ?? "")
    }

    // MARK: Internal

    let account: CodexAccount
    let isConnected: Bool
    let onSave: (String, String?) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.codexAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Account label", text: $nameDraft)
                        .settingsInput(width: 240)
                        .onSubmit(saveChanges)
                    Text(account.isDefault ? "Default" : "Profile")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.codexAccent)
                    StatusPill(title: isConnected ? "Connected" : "Not Connected", isConnected: isConnected)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Text("CODEX_HOME")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 126, alignment: .leading)
                    if account.isDefault {
                        SettingsReadonlyField(text: CodexHomeDirectory.path(for: account))
                    } else {
                        TextField("Codex home directory", text: $homeDirectoryDraft)
                            .settingsInput(width: 280)
                            .onSubmit(saveChanges)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
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
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .onChange(of: account) { _, updated in
            nameDraft = updated.name
            homeDirectoryDraft = updated.homeDirectory ?? ""
        }
    }

    // MARK: Private

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
