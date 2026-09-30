import MeterBarShared
import SwiftUI

/// GitHub Copilot's Providers-settings panel: a fine-grained token (Keychain),
/// whose billing MeterBar reads (personal plan, or an organization-managed
/// licence), and a plain statement of what MeterBar can and cannot show for the
/// account it found.
struct GitHubCopilotSettingsSection: View {
    // MARK: Internal

    let onChange: () -> Void

    var body: some View {
        SingleKeyProviderSettingsSection(
            service: .githubCopilot,
            logoKind: .githubCopilot,
            accent: MeterBarTheme.githubCopilotAccent,
            notice: String(
                localized: "settings.copilot.notice",
                defaultValue: """
                MeterBar reads Copilot billing through GitHub's documented billing API with a fine-grained \
                token you create (Plan: read for a personal plan). The token is stored in macOS Keychain and \
                sent only to api.github.com. GitHub documents an allowance only for organization budgets, so \
                other accounts show their usage state instead of a quota bar.
                """
            ),
            keyPlaceholder: String(localized: "settings.copilot.token_placeholder", defaultValue: "github_pat_…"),
            helpURL: URL(string: "https://github.com/settings/personal-access-tokens/new"),
            helpTitle: String(localized: "settings.copilot.get_token", defaultValue: "Get Token"),
            hasAccess: service.hasAccess,
            hasKey: service.hasToken,
            lastError: service.lastError,
            unauthenticatedDetail: String(
                localized: "settings.copilot.unauthenticated",
                defaultValue: "GitHub rejected the token. Create a new fine-grained token and paste it here."
            ),
            onSaveKey: { value in
                let saved = service.saveToken(value)
                if saved {
                    onChange()
                }
                return saved
            },
            onRemoveKey: {
                service.removeToken()
                onChange()
            },
            extra: {
                SettingsRowView(title: String(localized: "settings.copilot.billing", defaultValue: "Billing")) {
                    Picker("", selection: $scope) {
                        ForEach(GitHubCopilotBillingScope.allCases, id: \.self) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowView(
                    title: String(localized: "settings.copilot.username", defaultValue: "GitHub username")
                ) {
                    TextField("octocat", text: $username)
                        .settingsInput()
                        .frame(minWidth: 160, maxWidth: 240)
                }

                if scope == .organization {
                    SettingsRowView(
                        title: String(localized: "settings.copilot.organization", defaultValue: "Organization")
                    ) {
                        TextField("my-org", text: $organization)
                            .settingsInput()
                            .frame(minWidth: 160, maxWidth: 240)
                    }
                }

                SettingsRowView(title: "") {
                    Button(String(localized: "settings.copilot.save_account", defaultValue: "Save Account")) {
                        saveAccount()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!draftIsValid)
                }

                if let note = service.supportNote {
                    SettingsNotice(text: note, color: .secondary)
                }
            }
        )
    }

    // MARK: Private

    @ObservedObject private var service = GitHubCopilotService.shared
    @State private var scope = GitHubCopilotService.shared.configuration.scope
    @State private var username = GitHubCopilotService.shared.configuration.username ?? ""
    @State private var organization = GitHubCopilotService.shared.configuration.organization ?? ""

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedOrganization: String {
        organization.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Logins are validated before they can be saved: they end up in a URL path.
    private var draftIsValid: Bool {
        GitHubLogin.isValid(trimmedUsername)
            && (scope == .personal || GitHubLogin.isValid(trimmedOrganization))
    }

    private func saveAccount() {
        guard draftIsValid else {
            return
        }
        service.saveConfiguration(
            GitHubCopilotAccountConfig(
                scope: scope,
                username: trimmedUsername,
                organization: scope == .organization ? trimmedOrganization : nil
            )
        )
        onChange()
    }
}
