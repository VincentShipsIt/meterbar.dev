import MeterBarShared
import SwiftUI

/// Kimi Code's Providers-settings panel: the official sign-in when one is
/// found, plus an optional API key held in MeterBar's Keychain.
struct KimiCodeSettingsSection: View {
    let onChange: () -> Void

    var body: some View {
        SingleKeyProviderSettingsSection(
            service: .kimiCode,
            logoKind: .kimiCode,
            accent: MeterBarTheme.kimiCodeAccent,
            notice: String(
                localized: "settings.kimi.notice",
                defaultValue: """
                MeterBar reads the Kimi Code sign-in file read-only and sends the token only to \
                Kimi Code's usage endpoint. Kimi Code keeps ownership of refreshing it. \
                Or add a Kimi Code API key, stored in macOS Keychain.
                """
            ),
            keyPlaceholder: String(localized: "settings.kimi.key_placeholder", defaultValue: "Kimi Code API key"),
            helpURL: nil,
            helpTitle: "",
            hasAccess: service.hasAccess,
            hasKey: service.hasAPIKey,
            lastError: service.lastError,
            unauthenticatedDetail: String(
                localized: "settings.kimi.unauthenticated",
                defaultValue: "Kimi Code rejected the credential. Run /login in Kimi Code, or add an API key."
            ),
            onSaveKey: { value in
                let saved = service.saveAPIKey(value)
                if saved { onChange() }
                return saved
            },
            onRemoveKey: {
                service.removeAPIKey()
                onChange()
            },
            extra: {
                SettingsRowView(title: String(localized: "settings.kimi.signin", defaultValue: "Kimi Code sign-in")) {
                    Text(signInText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .task { await refreshProbe() }

                if let wallet = dataManager.metrics[.kimiCode]?.extraUsage, wallet.state != .unknown {
                    SettingsRowView(
                        title: String(localized: "settings.kimi.wallet", defaultValue: "Booster wallet"),
                        detail: ExtraUsageRow.detailText(wallet)
                    ) {
                        ExtraUsageStatusToggle(status: wallet)
                    }
                }
            }
        )
    }

    @ObservedObject private var service = KimiCodeService.shared
    @ObservedObject private var dataManager = UsageDataManager.shared
    @State private var probe: KimiCodeCredentialProbe?

    private var signInText: String {
        switch probe {
        case .ready:
            return String(localized: "settings.kimi.signin.ready", defaultValue: "Found")
        case .expired:
            return String(localized: "settings.kimi.signin.expired", defaultValue: "Expired — run /login")
        case .unreadable:
            return String(localized: "settings.kimi.signin.unreadable", defaultValue: "Unreadable")
        case .notFound, nil:
            return String(localized: "settings.kimi.signin.not_found", defaultValue: "Not found")
        }
    }

    private func refreshProbe() async {
        let service = service
        probe = await Task.detached(priority: .userInitiated) {
            service.credentialProbe()
        }.value
    }
}
