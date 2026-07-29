import AppKit
import MeterBarShared
import SwiftUI

/// Adds one Grok Build profile backed by an official `GROK_HOME` directory.
struct AddGrokAccountSheet: View {
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: .grok, size: 18, foregroundColor: MeterBarTheme.grokAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Grok Account").font(.headline)
                    Text("Use a separate GROK_HOME containing its CLI-managed auth.json.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Account name", text: $accountName).settingsInput()
                HStack(spacing: 8) {
                    TextField("Grok home directory", text: $homeDirectory).settingsInput()
                    Button("Choose", action: chooseHomeDirectory).buttonStyle(.bordered)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Account") {
                    onAdd(trimmedName, trimmedHomeDirectory)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(MeterBarTheme.Spacing.xxl)
        .frame(width: 520)
    }

    @Environment(\.dismiss)
    private var dismiss
    @State private var accountName = ""
    @State private var homeDirectory = ""

    private var trimmedName: String { accountName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHomeDirectory: String {
        homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canAdd: Bool { !trimmedName.isEmpty && !trimmedHomeDirectory.isEmpty }

    private func chooseHomeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            homeDirectory = url.path
            if trimmedName.isEmpty { accountName = url.lastPathComponent }
        }
    }
}
