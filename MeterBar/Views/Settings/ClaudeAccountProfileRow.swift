import AppKit
import MeterBarShared
import SwiftUI

// MARK: - AccountProfileRowMetrics

enum AccountProfileRowMetrics {
    static let labelWidth: CGFloat = 126
    static let fieldWidth: CGFloat = 280
    static let actionWidth: CGFloat = 28
}

// MARK: - AccountProfileRow

/// One editable Claude Code account row (name + config directory + enable /
/// reconnect / save / delete). Extracted verbatim from the SettingsView
/// monolith. The default profile cannot be removed.
struct AccountProfileRow: View {
    // MARK: Lifecycle

    init(
        account: ClaudeCodeAccount,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onReconnect: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.account = account
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onReconnect = onReconnect
        self.onRemove = onRemove
        _nameDraft = State(initialValue: account.name)
        _configDirectoryDraft = State(initialValue: Self.resolvedConfigDirectory(for: account))
    }

    // MARK: Internal

    let account: ClaudeCodeAccount
    let onEnabledChange: (Bool) -> Void
    let onSave: (String, String?) -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.isDefault ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .foregroundStyle(MeterBarTheme.claudeAccent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    accountFieldLabel("Account name")

                    TextField("Account label", text: $nameDraft)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .onSubmit(saveChanges)

                    // Migrated to the shared `MeterBarChip`. This was the 5th,
                    // odd-one-out recipe (`.thinMaterial` + glassCardStroke); the
                    // `.glass` chip gives it the standard Liquid-Glass capsule
                    // while keeping the Default/Profile role tint.
                    MeterBarChip(
                        account.isDefault ? "Default" : "Profile",
                        tint: account.isDefault ? MeterBarTheme.appAccent : MeterBarTheme.claudeAccent,
                        style: .glass
                    )
                }

                HStack(spacing: 8) {
                    accountFieldLabel("Config directory")

                    TextField("Config directory", text: $configDirectoryDraft)
                        .settingsInput(width: AccountProfileRowMetrics.fieldWidth)
                        .onSubmit(saveChanges)

                    Button {
                        chooseConfigDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Choose config directory")
                }

                if account.isDefault {
                    Text("Defaults to ~/.claude or $CLAUDE_CONFIG_DIR; clear the field to restore that default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, AccountProfileRowMetrics.labelWidth + 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { account.isEnabled },
                    set: onEnabledChange
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(account.isEnabled ? "Disable account" : "Enable account")

                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .help("Reconnect Claude profile")

                Button(action: saveChanges) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: AccountProfileRowMetrics.actionWidth)
                .disabled(!hasChanges || !canSave)
                .help("Save account changes")

                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: AccountProfileRowMetrics.actionWidth)
                    .help("Delete account")
                } else {
                    Color.clear
                        .frame(width: AccountProfileRowMetrics.actionWidth, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, MeterBarTheme.Spacing.md)
        .onChange(of: account) { _, updatedAccount in
            nameDraft = updatedAccount.name
            configDirectoryDraft = Self.resolvedConfigDirectory(for: updatedAccount)
        }
    }

    // MARK: Private

    @State private var nameDraft: String
    @State private var configDirectoryDraft: String

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConfigDirectory: String {
        configDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedConfigDirectory: String {
        Self.resolvedConfigDirectory(for: account)
    }

    private var hasChanges: Bool {
        trimmedName != account.name ||
            trimmedConfigDirectory != resolvedConfigDirectory
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (account.isDefault || !trimmedConfigDirectory.isEmpty)
    }

    private func saveChanges() {
        guard hasChanges, canSave else {
            return
        }
        let changedConfigDirectory = trimmedConfigDirectory == resolvedConfigDirectory
            ? nil
            : trimmedConfigDirectory
        onSave(trimmedName, changedConfigDirectory)
    }

    private func accountFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(width: AccountProfileRowMetrics.labelWidth, alignment: .leading)
    }

    private static func resolvedConfigDirectory(for account: ClaudeCodeAccount) -> String {
        account.configDirectory ?? (account.isDefault ? ClaudeCodeAccount.defaultConfigDirectory() : "")
    }

    private func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            configDirectoryDraft = url.path
        }
    }
}
