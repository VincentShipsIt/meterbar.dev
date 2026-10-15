import MeterBarShared
import SwiftUI

/// Claude Platform's Providers-settings panel: the Console session cookie
/// (Keychain) and the balance, spend and expiry the last refresh read.
struct ClaudePlatformSettingsSection: View {
    let onChange: () -> Void

    var body: some View {
        SingleKeyProviderSettingsSection(
            service: .claudePlatform,
            logoKind: .claudePlatform,
            accent: MeterBarTheme.claudePlatformAccent,
            notice: String(
                localized: "settings.claude_platform.notice",
                defaultValue: """
                Reads your Claude Console API credit balance and credit grants, including the monthly \
                API credit a Max or Team plan includes. An API key cannot read billing, so sign in at \
                platform.claude.com, copy the Cookie header from any request there, and paste it \
                below. MeterBar keeps only the sessionKey value, in macOS Keychain, and sends it to \
                platform.claude.com alone. It expires periodically; paste a fresh one when asked. \
                These are the Console's own billing endpoints, not a documented API.
                """
            ),
            keyPlaceholder: String(
                localized: "settings.claude_platform.key_placeholder",
                defaultValue: "Cookie header from platform.claude.com"
            ),
            helpURL: URL(string: "https://platform.claude.com/settings/billing"),
            helpTitle: String(localized: "settings.claude_platform.open_console", defaultValue: "Open Console"),
            hasAccess: service.hasAccess,
            hasKey: service.hasSessionKey,
            lastError: service.lastError,
            unauthenticatedDetail: String(
                localized: "settings.claude_platform.unauthenticated",
                defaultValue: """
                Claude Console rejected the session. Sign in at platform.claude.com and paste a fresh \
                Cookie header.
                """
            ),
            onSaveKey: { value in
                let saved = service.saveSessionKey(value)
                if saved { onChange() }
                return saved
            },
            onRemoveKey: {
                service.removeSessionKey()
                onChange()
            },
            extra: {
                if let note = service.statusNote ?? service.balanceNote {
                    SettingsRowView(
                        title: String(localized: "settings.claude_platform.credit", defaultValue: "API credit")
                    ) {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        )
    }

    @ObservedObject private var service = ClaudePlatformService.shared
}
