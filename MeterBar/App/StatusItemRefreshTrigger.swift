import Combine
import Foundation

/// Fan-in of everything that can change the menu-bar title, extracted from
/// `observeUsageMetrics()` in `MeterBarApp.swift` (C1 split).
///
/// The original was eight separate `.sink`s whose bodies were byte-identical
/// apart from the first: every one hopped through `Task { @MainActor in ... }`
/// and then re-read `UsageDataManager.shared.metrics`. `@Published` fires on
/// `willSet`, so a sink that reads the singleton back on the next main-actor
/// hop observes the committed value — which makes "publish the value" and
/// "publish `Void`, then re-read" equivalent. Collapsing them to a single
/// `Void` stream is therefore behaviour-preserving, and the subscriber count
/// stays the same because `MergeMany` subscribes to each upstream.
enum StatusItemRefreshTrigger {
    /// The individual upstreams, exposed so tests can assert none were dropped
    /// in the collapse.
    static func sources() -> [AnyPublisher<Void, Never>] {
        let claudeAccountChanges = Publishers.Merge3(
            ClaudeCodeAccountStore.shared.$customAccounts.map { _ in () },
            ClaudeCodeAccountStore.shared.$defaultAccountConfigDirectory.map { _ in () },
            ClaudeCodeAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }
        )
        // Codex account identity fields can change without `customAccounts`
        // republishing; fan in every published default/custom field that
        // affects menu-bar layout or labels.
        let codexAccountChanges = Publishers.MergeMany([
            CodexAccountStore.shared.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            CodexAccountStore.shared.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            CodexAccountStore.shared.$defaultAccountHomeDirectory.map { _ in () }.eraseToAnyPublisher(),
            CodexAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
        ])
        // Grok mirrors Claude/Codex: label, enablement, and custom profile set
        // all reshape account-scoped menu-bar items.
        let grokAccountChanges = Publishers.MergeMany([
            GrokAccountStore.shared.$customAccounts.map { _ in () }.eraseToAnyPublisher(),
            GrokAccountStore.shared.$defaultAccountName.map { _ in () }.eraseToAnyPublisher(),
            GrokAccountStore.shared.$defaultAccountIsEnabled.map { _ in () }.eraseToAnyPublisher(),
        ])
        let displayPreferences = MenuBarDisplayPreferencesStore.shared
        let displayPreferenceChanges = Publishers.MergeMany([
            displayPreferences.$pinnedCandidateKey.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$presentationMode.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$labelMetric.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$labelSize.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$windowMode.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$highContrast.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$showsExhaustedResetCountdown.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$followsFocusedApp.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$focusAppMapping.map { _ in () }.eraseToAnyPublisher(),
            // Rotation reshapes the merged item the moment it is toggled, and a
            // new interval has to reschedule the timer rather than wait out the
            // old cadence.
            displayPreferences.$rotatesProviders.map { _ in () }.eraseToAnyPublisher(),
            displayPreferences.$rotationInterval.map { _ in () }.eraseToAnyPublisher()
        ])

        // Which app the user is working in, when focus following is on. The
        // monitor publishes nil (and observes nothing) while the feature is off,
        // so this upstream is inert until the user opts in.
        let focusedAppChanges = FrontmostAppMonitor.shared.$bundleIdentifier.map { _ in () }

        // Which accounts own items, and which one the switcher shows. Without
        // these, picking an account from the switcher submenu (or toggling one
        // in Settings) only persists the choice — the menu bar keeps the old
        // layout until some unrelated refresh happens to fire.
        let accountSelectionChanges = Publishers.Merge(
            MenuBarAccountSelectionStore.shared.$selectedAccountKeys.map { _ in () },
            MenuBarAccountSelectionStore.shared.$mergedAccountKey.map { _ in () }
        )

        let metricsChanges = UsageDataManager.shared.$metrics.map { _ in () }
        let claudeMetricsChanges = UsageDataManager.shared.$claudeCodeAccountMetrics.map { _ in () }
        let codexMetricsChanges = UsageDataManager.shared.$codexAccountMetrics.map { _ in () }
        let grokMetricsChanges = UsageDataManager.shared.$grokAccountMetrics.map { _ in () }
        let visibilityChanges = ProviderVisibilityStore.shared.$hiddenServices.map { _ in () }
        let parseHealthChanges = ProviderParseHealthStore.shared.$records.map { _ in () }

        return [
            metricsChanges.eraseToAnyPublisher(),
            claudeMetricsChanges.eraseToAnyPublisher(),
            codexMetricsChanges.eraseToAnyPublisher(),
            grokMetricsChanges.eraseToAnyPublisher(),
            claudeAccountChanges.eraseToAnyPublisher(),
            codexAccountChanges.eraseToAnyPublisher(),
            grokAccountChanges.eraseToAnyPublisher(),
            accountSelectionChanges.eraseToAnyPublisher(),
            visibilityChanges.eraseToAnyPublisher(),
            parseHealthChanges.eraseToAnyPublisher(),
            displayPreferenceChanges.eraseToAnyPublisher(),
            focusedAppChanges.eraseToAnyPublisher()
        ]
    }

    /// One stream to subscribe to. Every `@Published` upstream replays its
    /// current value on subscribe, so this fires once immediately — which is
    /// what the trailing direct `updateStatusItem(...)` call used to do.
    static func publisher() -> AnyPublisher<Void, Never> {
        let merged = Publishers.MergeMany(sources())
        return merged.eraseToAnyPublisher()
    }
}
