import MeterBarShared
import SwiftUI

/// Muse Code's Providers panel. There is no API-key field: the Muse CLI owns
/// the login, and MeterBar only reads it.
struct MuseCodeSettingsSection: View {
    let onChange: () -> Void

    var body: some View {
        SettingsPanelSection(
            title: ServiceType.museCode.displayName,
            logoKind: .museCode,
            color: MeterBarTheme.museCodeAccent
        ) {
            SettingsNotice(
                text: String(
                    localized: "settings.muse.notice",
                    defaultValue: """
                    MeterBar reads the Muse CLI sign-in read-only and asks api.meta.ai for the Muse Code \
                    quota. The Muse CLI owns login and refresh. The first Connect may show a Keychain \
                    prompt — choose Always Allow. Background refresh never prompts. A fresh `muse login` \
                    can require allowing access again.
                    """
                ),
                color: .secondary
            )

            SettingsRowView(title: String(localized: "settings.muse.connection", defaultValue: "Connection")) {
                StatusPill(title: connectionTitle, isConnected: probe == .ready)
            }

            SettingsRowView(title: String(localized: "settings.muse.plan", defaultValue: "Plan")) {
                Text(service.planName ?? String(localized: "settings.muse.plan.unknown", defaultValue: "Unknown"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let statusNote = service.statusNote {
                SettingsRowView(title: String(localized: "settings.muse.status", defaultValue: "Status")) {
                    Text(statusNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let lastError = service.lastError, service.statusNote == nil {
                EmptyStateCard(
                    systemImage: "exclamationmark.triangle.fill",
                    title: String(localized: "settings.muse.error_title", defaultValue: "Not connected"),
                    message: errorDetail(lastError),
                    tone: .warning
                )
            }

            Button(String(localized: "settings.muse.connect", defaultValue: "Connect Muse Code")) {
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
            .padding(.vertical, MeterBarTheme.Spacing.sm)
        }
        .task { await refreshProbe() }
    }

    @ObservedObject private var service = MuseCodeService.shared
    @State private var probe: MuseCodeCredentialProbe?
    @State private var isConnecting = false

    private var connectionTitle: String {
        switch probe {
        case .ready:
            return String(localized: "settings.muse.connected", defaultValue: "Connected")
        case .needsConnect, .needsKeychainAccess:
            return String(localized: "settings.muse.keychain", defaultValue: "Keychain access needed")
        case .notSignedIn:
            return String(localized: "settings.muse.signed_out", defaultValue: "Not signed in")
        case .noSubscription:
            return String(localized: "settings.muse.no_subscription", defaultValue: "No subscription")
        case .rejectedToken, .unreadable:
            return String(localized: "settings.muse.attention", defaultValue: "Needs attention")
        case .disabled, nil:
            return String(localized: "settings.muse.not_connected", defaultValue: "Not connected")
        }
    }

    private func errorDetail(_ error: ServiceError) -> String {
        switch error {
        case .notAuthenticated:
            return MuseCodeCopy.reconnect
        default:
            return error.localizedDescription
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            _ = try await service.connect()
        } catch {
            // `lastError` and `statusNote` already carry the authored state.
        }
        await refreshProbe()
        onChange()
    }

    private func refreshProbe() async {
        probe = service.credentialProbe()
    }
}
