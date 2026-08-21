import Foundation
import MeterBarShared

/// Which account identities still exist after a provider-account mutation.
///
/// Enabling, disabling, deleting, or untracking an account changes what the
/// menu bar, the widget, and Session Wake are allowed to point at. Computing
/// that in one value type keeps the three downstream sets derived from the same
/// account lists — in particular, *every* provider is projected on every pass,
/// so reconciling after a Codex change cannot prune a Claude or Grok selection
/// as collateral damage.
struct ProviderAccountSelectionAvailability {
    let menuBarKeys: Set<String>
    let widgetAccountIdentifiers: Set<WidgetAccountIdentifier>
    let enabledCodexAccountIDs: [UUID]

    init(
        claudeAccounts: [ClaudeCodeAccount],
        codexAccounts: [CodexAccount],
        grokAccounts: [GrokAccount],
        openRouterAccounts: [OpenRouterAccount] = [],
        enabledServices: Set<ServiceType>
    ) {
        menuBarKeys = Set(
            MenuBarAccountCatalog.identities(
                claudeAccounts: claudeAccounts,
                codexAccounts: codexAccounts,
                grokAccounts: grokAccounts,
                openRouterAccounts: openRouterAccounts,
                enabledServices: enabledServices
            )
            .filter(\.isEnabled)
            .map(\.key)
        )

        widgetAccountIdentifiers = Set(
            WidgetSettingsAccountProjection.options(
                enabledServices: enabledServices,
                claudeAccounts: claudeAccounts,
                codexAccounts: codexAccounts,
                grokAccounts: grokAccounts,
                openRouterAccounts: openRouterAccounts
            )
            .map(\.id)
        )

        enabledCodexAccountIDs = enabledServices.contains(.codexCli)
            ? codexAccounts.filter(\.isEnabled).map(\.id)
            : []
    }
}

/// Applies an availability projection to everything that stores an account
/// reference, so a disabled or deleted profile cannot linger as a selected
/// status item, a widget account, or an armed Session Wake target.
enum ProviderAccountSelectionReconciler {
    @MainActor
    static func apply(
        _ availability: ProviderAccountSelectionAvailability,
        menuBarSelection: MenuBarAccountSelectionStore,
        widgetPreferences: WidgetPreferencesStore,
        sessionWakeSettings: SessionWakeSettingsStore
    ) {
        menuBarSelection.reconcile(availableKeys: availability.menuBarKeys)
        widgetPreferences.reconcileAvailableAccounts(availability.widgetAccountIdentifiers)
        sessionWakeSettings.reconcileCodexAccounts(available: availability.enabledCodexAccountIDs)
    }
}
