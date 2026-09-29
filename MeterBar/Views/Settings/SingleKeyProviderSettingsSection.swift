import MeterBarShared
import SwiftUI

/// The Providers-settings panel shared by the single-credential providers
/// (Kimi Code, Z.ai, GitHub Copilot): a connection row, a Keychain-backed API
/// key field, and the provider's own facts in `extra`.
///
/// The key never leaves this view except through `onSaveKey`, which writes it
/// to the Keychain; the field is cleared as soon as it is saved and the saved
/// key is only ever shown as a mask.
struct SingleKeyProviderSettingsSection<Extra: View>: View {
    let service: ServiceType
    let logoKind: ProviderLogoKind
    let accent: Color
    let notice: String
    let keyPlaceholder: String
    let helpURL: URL?
    let helpTitle: String
    let hasAccess: Bool
    let hasKey: Bool
    let lastError: ServiceError?
    /// Copy for a rejected credential; the provider knows which recovery applies.
    let unauthenticatedDetail: String
    let onSaveKey: (String) -> Bool
    let onRemoveKey: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        SettingsPanelSection(title: service.displayName, logoKind: logoKind, color: accent) {
            SettingsNotice(text: notice, color: .secondary)

            SettingsRowView(title: "Connection") {
                HStack(spacing: 8) {
                    StatusPill(
                        title: hasAccess ? "Connected" : "Not Connected",
                        isConnected: hasAccess
                    )

                    if let helpURL {
                        Button(helpTitle) {
                            NSWorkspace.shared.open(helpURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            extra()

            if let lastError {
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Not connected",
                    message: errorDetail(lastError),
                    tone: .warning
                )
            }

            SettingsDivider()

            HStack(spacing: 8) {
                if hasKey {
                    SettingsReadonlyField(text: "••••••••••••••••")

                    Button("Remove", role: .destructive, action: onRemoveKey)
                        .buttonStyle(.bordered)
                } else {
                    SecureField(keyPlaceholder, text: $draft)
                        .settingsInput()
                        .frame(minWidth: 220, maxWidth: 340)

                    Button("Save") {
                        if onSaveKey(draft) {
                            draft = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, MeterBarTheme.Spacing.sm)
        }
    }

    @State private var draft = ""

    private func errorDetail(_ error: ServiceError) -> String {
        switch error {
        case .notAuthenticated:
            return unauthenticatedDetail
        default:
            return error.localizedDescription
        }
    }
}
