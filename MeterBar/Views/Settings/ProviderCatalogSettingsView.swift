import MeterBarShared
import SwiftUI

/// The "All Providers" page: every provider MeterBar can track, whether or not
/// it is currently tracked.
///
/// The sidebar's Providers group lists only what the user tracks, so this page
/// is what keeps the rest reachable — turn one on here and it takes a sidebar
/// row; turn the selected one off from its own page and the selection lands back
/// here. That split is also what keeps the sidebar short as the catalog grows:
/// this page scales with `ServiceType.allCases`, the sidebar with the enabled
/// set.
struct ProviderCatalogSettingsView: View {
    // MARK: Internal

    /// Every provider, in display order. Exposed so tests can assert the catalog
    /// stays complete — an untracked provider missing from this list would have
    /// no sidebar row and no page, and so be unreachable from settings entirely.
    static let catalog: [ServiceType] = ServiceType.allCases.sorted { $0.sortOrder < $1.sortOrder }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPanelSection(
                title: "All Providers",
                systemImage: "square.grid.2x2",
                color: MeterBarTheme.appAccent
            ) {
                ForEach(Self.catalog) { service in
                    catalogRow(for: service)
                }
            }
        }
    }

    // MARK: Private

    @StateObject private var navigation = DashboardNavigationStore.shared
    @StateObject private var dataManager = UsageDataManager.shared
    @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
    @StateObject private var codexCliService = CodexCliLocalService.shared
    @StateObject private var codexAccountStore = CodexAccountStore.shared
    @StateObject private var grokAccountStore = GrokAccountStore.shared
    @StateObject private var openRouterAccountStore = OpenRouterAccountStore.shared
    @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
    @StateObject private var cursorService = CursorLocalService.shared
    @StateObject private var openRouterService = OpenRouterService.shared
    @StateObject private var grokService = GrokCLIUsageService.shared
    @StateObject private var providerVisibility = ProviderVisibilityStore.shared
    @StateObject private var parseHealthStore = ProviderParseHealthStore.shared

    private var providerSnapshots: [ProviderSnapshot] {
        ProviderSnapshotBuilder.snapshots(
            .live(
                stores: .init(
                    dataManager: dataManager,
                    claudeAccounts: claudeAccountStore.accounts,
                    codexAccounts: codexAccountStore.accounts,
                    grokAccounts: grokAccountStore.accounts,
                    openRouterAccounts: openRouterAccountStore.accounts,
                    enabledServices: providerVisibility.enabledServices,
                    claudeCodeService: claudeCodeService,
                    codexCliService: codexCliService,
                    cursorService: cursorService,
                    openRouterService: openRouterService,
                    grokService: grokService
                ),
                parseHealth: parseHealthStore.records
            )
        )
    }

    /// What tracking this provider gets you, shown before it has any data to
    /// show. Previously the subtitle of the General tab's duplicate toggle list.
    private static func summary(for service: ServiceType) -> String {
        switch service {
        case .claudeCode: return "Track Pro/Max quota via Claude CLI profiles."
        case .codexCli: return "Track Codex CLI quota from local Codex auth."
        case .cursor: return "Track Cursor quota from local Cursor state."
        case .openRouter: return "Track credit balance, spend, and per-key limits."
        case .grok: return "Track Grok Build session and weekly quota from its cached CLI login."
        }
    }

    private func catalogRow(for service: ServiceType) -> some View {
        let facts = ProviderSettingsFacts.live(for: service, snapshots: providerSnapshots)
        let isTracked = providerVisibility.isEnabled(service)

        return HStack(alignment: .center, spacing: 10) {
            ProviderLogoView(
                kind: .forService(service),
                size: 20,
                foregroundColor: MeterBarTheme.accent(for: service)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(Self.summary(for: service))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            Text(facts.statusText)
                .font(.caption)
                .foregroundStyle(facts.statusColor)
                .lineLimit(1)

            Toggle("", isOn: trackedBinding(for: service))
                .labelsHidden()
                .meterBarSwitch()
                .accessibilityLabel("Track \(service.displayName)")

            // Only tracked providers have a sidebar row, so only they can be
            // selected — an untracked provider would leave the sidebar with a
            // selection it can't highlight.
            Button {
                navigation.selectSettingsItem(.provider(service))
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open \(service.displayName) settings")
            .accessibilityLabel("Open \(service.displayName) settings")
            .opacity(isTracked ? 1 : 0)
            .disabled(!isTracked)
        }
    }

    private func trackedBinding(for service: ServiceType) -> Binding<Bool> {
        Binding(
            get: { providerVisibility.isEnabled(service) },
            set: { isEnabled in
                providerVisibility.set(service, isEnabled: isEnabled)
                Task {
                    await dataManager.refreshAll()
                }
            }
        )
    }
}
