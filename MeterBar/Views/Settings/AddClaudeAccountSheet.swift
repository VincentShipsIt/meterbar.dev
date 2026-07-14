import AppKit
import MeterBarShared
import SwiftUI

/// Sheet for adding a Claude Code profile backed by a separate
/// `CLAUDE_CONFIG_DIR`. Extracted verbatim from the SettingsView monolith.
struct AddClaudeAccountSheet: View {
    // MARK: Internal

    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: .claude, size: 18, foregroundColor: MeterBarTheme.claudeAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Claude Account")
                        .font(.headline)
                    Text("Use a separate CLAUDE_CONFIG_DIR for this profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Work", text: $accountName)
                        .settingsInput()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Config directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Path", text: $configDirectory)
                            .settingsInput()
                        Button("Choose") {
                            chooseConfigDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Account") {
                    guard canAdd else {
                        return
                    }
                    onAdd(trimmedName, trimmedConfigDirectory)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    // MARK: Private

    @Environment(\.dismiss)
    private var dismiss

    @State private var accountName = ""
    @State private var configDirectory = ""

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConfigDirectory: String {
        configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty && !trimmedConfigDirectory.isEmpty
    }

    private func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"

        if panel.runModal() == .OK, let url = panel.url {
            configDirectory = url.path
            if trimmedName.isEmpty {
                accountName = url.lastPathComponent
            }
        }
    }
}
