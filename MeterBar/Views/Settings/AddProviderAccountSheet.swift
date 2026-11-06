import AppKit
import MeterBarShared
import SwiftUI

/// Modal sheet for adding one multi-account CLI profile. Shared by Claude,
/// Codex, and Grok — only branding and path copy differ.
///
/// Naming the account is enough: with the folder left empty MeterBar creates a
/// default profile folder and, if asked, starts the provider's own CLI login
/// scoped to it. Picking an existing folder still works unchanged.
struct AddProviderAccountSheet: View {
    let loginProvider: AccountLoginProvider
    let providerName: String
    let logoKind: ProviderLogoKind
    let accent: Color
    let subtitle: String
    let pathFieldLabel: String
    /// Receives the account name, the resolved profile folder, and whether to
    /// start the provider's login once the account is added.
    let onAdd: (String, String, Bool) -> Void

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
                        TextField(defaultPathDisplay, text: $path)
                            .settingsInput()
                        Button("Choose", action: chooseDirectory)
                            .buttonStyle(.bordered)
                    }
                    Text(pathHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(
                    "Sign in to \(providerName) after adding",
                    isOn: $startsLogin
                )
                .toggleStyle(.checkbox)
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(startsLogin ? "Add & Sign In" : "Add Account") {
                    onAdd(trimmedName, resolvedPath, startsLogin)
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
    @State private var startsLogin = true

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folder a blank field falls back to, derived from the account name.
    private var defaultPath: String {
        AccountSetup.defaultDirectory(
            for: loginProvider,
            accountName: trimmedName.isEmpty ? "account" : trimmedName
        )
    }

    private var defaultPathDisplay: String {
        ServiceSupport.compactPathForDisplay(defaultPath)
    }

    private var resolvedPath: String {
        trimmedPath.isEmpty ? defaultPath : trimmedPath
    }

    private var pathHelp: String {
        let variable = loginProvider.environmentVariable
        return trimmedPath.isEmpty
            ? "MeterBar creates \(defaultPathDisplay) for \(variable). "
            + "Choose a folder to use an existing profile instead."
            : "Used as \(variable). A missing folder is created; an existing one is left as it is."
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty
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
