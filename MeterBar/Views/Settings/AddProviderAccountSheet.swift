import AppKit
import MeterBarShared
import SwiftUI

/// Modal sheet for adding one multi-account CLI profile. Shared by Claude,
/// Codex, and Grok — only branding and path copy differ.
struct AddProviderAccountSheet: View {
    let providerName: String
    let logoKind: ProviderLogoKind
    let accent: Color
    let subtitle: String
    let pathFieldLabel: String
    let pathPlaceholder: String
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: logoKind, size: 18, foregroundColor: accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(providerName) Account")
                        .font(.headline)
                    Text(subtitle)
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
                    Text(pathFieldLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(pathPlaceholder, text: $path)
                            .settingsInput()
                        Button("Choose", action: chooseDirectory)
                            .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Account") {
                    onAdd(trimmedName, trimmedPath)
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
    @State private var path = ""

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty && !trimmedPath.isEmpty
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if trimmedName.isEmpty {
                accountName = url.lastPathComponent
            }
        }
    }
}
