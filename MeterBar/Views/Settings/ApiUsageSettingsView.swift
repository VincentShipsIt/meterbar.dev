import AppKit
import MeterBarShared
import SwiftUI

/// The "API Usage" settings tab: the cross-provider extra-usage overview plus
/// organization admin-key entry for pay-as-you-go API cost estimation.
/// Extracted from the SettingsView monolith.
struct ApiUsageSettingsView: View {
    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showExtraUsageSection {
                extraUsageSection
            }
            apiUsageSection
        }
    }

    // MARK: Private

    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var authManager = AuthenticationManager.shared
    @StateObject private var apiUsageStore = ApiUsageStore.shared

    @State private var claudeAdminKeyDraft = ""
    @State private var openaiAdminKeyDraft = ""

    private var showExtraUsageSection: Bool {
        (providerVisibility.isEnabled(.claudeCode) && claudeExtraUsageStatus != nil)
            || providerVisibility.isEnabled(.codexCli)
    }

    private var claudeExtraUsageStatus: ExtraUsageStatus? {
        ExtraUsageDisplayPolicy.visibleStatus(
            for: .claudeCode,
            status: dataManager.metrics[.claudeCode]?.extraUsage
        )
    }

    private var extraUsageSection: some View {
        SettingsPanelSection(title: "Extra Usage", systemImage: "creditcard", color: MeterBarTheme.warning) {
            SettingsNotice(
                text: "Extra usage (Claude) and credits (Codex) let a provider bill overage beyond your "
                    + "plan once your quota is exhausted. \"Off\" means usage is capped at your subscription.",
                color: .secondary
            )

            if providerVisibility.isEnabled(.claudeCode) {
                if let claudeExtraUsageStatus {
                    ExtraUsageRow(
                        title: "Claude Code",
                        status: claudeExtraUsageStatus,
                        manageURL: "https://claude.ai/settings"
                    )
                }
            }

            if providerVisibility.isEnabled(.codexCli) {
                ExtraUsageRow(
                    title: "OpenAI Codex",
                    status: dataManager.metrics[.codexCli]?.extraUsage,
                    manageURL: "https://chatgpt.com"
                )
            }
        }
    }

    private var apiUsageSection: some View {
        SettingsPanelSection(
            title: "API Usage (organization)",
            systemImage: "network",
            color: MeterBarTheme.appAccent
        ) {
            SettingsNotice(
                text: "Paste an organization admin key to estimate pay-as-you-go API cost "
                    + "(Anthropic / OpenAI) from available usage and approximate list rates. "
                    + "Provider usage data may be incomplete and is not a billing statement. "
                    + "Keys are stored in the macOS Keychain and only used against the provider's usage API.",
                color: .secondary
            )

            adminKeyRow(
                provider: .anthropic,
                draft: $claudeAdminKeyDraft,
                placeholder: "sk-ant-admin...",
                helpURL: "https://console.anthropic.com/settings/admin-keys"
            )

            SettingsDivider()

            adminKeyRow(
                provider: .openai,
                draft: $openaiAdminKeyDraft,
                placeholder: "OpenAI admin key",
                helpURL: "https://platform.openai.com/settings/organization/admin-keys"
            )
        }
    }

    private func adminKeyRow(
        provider: ApiProvider,
        draft: Binding<String>,
        placeholder: String,
        helpURL: String
    ) -> some View {
        let connected = authManager.isAuthenticated(provider)
        return AdminKeySettingsRow(
            provider: provider,
            connected: connected,
            draft: draft,
            placeholder: placeholder,
            onSave: {
                saveAdminKey(provider, draft: draft)
            },
            onRemove: {
                authManager.removeAdminKey(for: provider)
                Task { await apiUsageStore.refresh() }
            },
            onHelp: {
                if let url = URL(string: helpURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    private func saveAdminKey(_ provider: ApiProvider, draft: Binding<String>) {
        guard authManager.setAdminKey(draft.wrappedValue, for: provider) else {
            return
        }
        draft.wrappedValue = ""
        Task { await apiUsageStore.refresh() }
    }
}
