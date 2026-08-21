import MeterBarShared
import SwiftUI

/// Modal sheet for adding one OpenRouter API key. The key goes straight into
/// the Keychain via `onAdd`; the sheet never stores or logs it.
struct AddProviderAPIKeySheet: View {
    let providerName: String
    let logoKind: ProviderLogoKind
    let accent: Color
    let subtitle: String
    let keyPlaceholder: String
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProviderLogoView(kind: logoKind, size: 18, foregroundColor: accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(providerName) Key")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Work", text: $accountName)
                        .settingsInput()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(keyPlaceholder, text: $apiKey)
                        .settingsInput()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Key") {
                    onAdd(trimmedName, trimmedKey)
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
    @State private var apiKey = ""

    private var trimmedName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty && !trimmedKey.isEmpty
    }
}
