import MeterBarShared
import SwiftUI

extension ProviderSettingsFacts {
    /// Builds a provider's facts from the live shared services.
    ///
    /// This is the only place that switches over `ServiceType` to read provider
    /// state. The Providers page and the settings sidebar's health dot both come
    /// through here, so the dot and the page's Status row cannot drift apart —
    /// and adding a provider means touching one switch, not two call sites.
    ///
    /// `snapshots` is the caller's already-built snapshot list (filtered or not);
    /// only this provider's entries are read from it.
    @MainActor
    static func live(for service: ServiceType, snapshots: [ProviderSnapshot]) -> ProviderSettingsFacts {
        let matching = snapshots.filter { $0.service == service }

        let live: (hasAccess: Bool, subscription: String?, tier: String?, error: String?) =
            switch service {
            case .claudeCode:
                (
                    ClaudeCodeLocalService.shared.hasAccess,
                    ClaudeCodeLocalService.shared.subscriptionType,
                    ClaudeCodeLocalService.shared.rateLimitTier,
                    ClaudeCodeLocalService.shared.lastError?.localizedDescription
                )
            case .codexCli:
                codexLiveState()
            case .cursor:
                (
                    CursorLocalService.shared.hasAccess,
                    CursorLocalService.shared.subscriptionType,
                    nil,
                    CursorLocalService.shared.lastError?.localizedDescription
                )
            case .openRouter:
                (
                    OpenRouterService.shared.hasAccess,
                    nil,
                    nil,
                    OpenRouterService.shared.lastError?.localizedDescription
                )
            case .grok:
                grokLiveState()
            }

        return ProviderSettingsFacts(
            service: service,
            isEnabled: ProviderVisibilityStore.shared.isEnabled(service),
            hasAccess: live.hasAccess,
            subscriptionType: live.subscription,
            rateLimitTier: live.tier,
            errorText: live.error,
            updatedText: matching.filter(\.hasMetrics).map(\.updatedText).first ?? "No data",
            worstBand: matching.compactMap(\.band).max(by: { $0.severity < $1.severity }),
            codexAuthFileDisplayPath: CodexHomeDirectory.authFileDisplayPath(
                for: CodexAccountStore.shared.accounts.first(where: \.isDefault) ?? .defaultAccount
            )
        )
    }

    /// Codex is connected when *any* enabled profile has a usable login: each
    /// profile owns a `CODEX_HOME`, so a signed-in custom profile keeps the
    /// Status row and the sidebar health dot honest even with the default
    /// sentinel logged out or disabled.
    @MainActor
    private static func codexLiveState() -> (
        hasAccess: Bool,
        subscription: String?,
        tier: String?,
        error: String?
    ) {
        let service = CodexCliLocalService.shared
        return (
            service.hasAccess(in: CodexAccountStore.shared.enabledAccounts),
            service.subscriptionType,
            nil,
            service.lastError?.localizedDescription
        )
    }

    @MainActor
    private static func grokLiveState() -> (
        hasAccess: Bool,
        subscription: String?,
        tier: String?,
        error: String?
    ) {
        let service = GrokCLIUsageService.shared
        let accounts = GrokAccountStore.shared.enabledAccounts
        return (
            accounts.contains(where: service.canAccess(account:)),
            service.subscriptionType,
            nil,
            service.firstError(for: accounts)?.localizedDescription
        )
    }
}
