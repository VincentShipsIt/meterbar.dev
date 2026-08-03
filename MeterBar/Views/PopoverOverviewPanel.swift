import Foundation
import MeterBarShared
import SwiftUI

/// The popover's scrolling body: first-run callout, empty state, setup
/// checklist, and the provider card stack.
struct PopoverOverviewPanel: View {
    let snapshots: [ProviderSnapshot]
    let openDashboard: () -> Void
    // Provider status now lives in the popover's top bar, so the panel no longer
    // renders a status card; `openStatusDetail` is retained for source/test compat.
    let openStatusDetail: () -> Void
    let openProviderOverview: (ProviderSnapshot) -> Void
    /// Hover-driven open for a provider card (opens its detail panel on pointer
    /// enter). Optional so existing/test call sites stay valid.
    var hoverProviderOverview: ((ProviderSnapshot, Bool) -> Void)?
    let claudeDefaultAccountEnabled: Bool
    let claudeEnabledCustomAccountIDs: [UUID]
    let claudeEnabledAccountMetrics: [UsageMetrics]
    let grokAccounts: [GrokAccount]

    @State private var setupReports: [ProviderReadiness] = []
    @StateObject private var onboarding = FirstRunOnboardingStore.shared
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    // Explicit initializer: the private `@State`/`@StateObject` storage would lower
    // the synthesized memberwise initializer to file-private, so this keeps the
    // panel constructible from the smoke-test target (and other modules).
    init(
        snapshots: [ProviderSnapshot],
        openDashboard: @escaping () -> Void,
        openStatusDetail: @escaping () -> Void,
        openProviderOverview: @escaping (ProviderSnapshot) -> Void,
        hoverProviderOverview: ((ProviderSnapshot, Bool) -> Void)? = nil,
        claudeDefaultAccountEnabled: Bool = true,
        claudeEnabledCustomAccountIDs: [UUID] = [],
        claudeEnabledAccountMetrics: [UsageMetrics] = [],
        grokAccounts: [GrokAccount] = [.defaultAccount]
    ) {
        self.snapshots = snapshots
        self.openDashboard = openDashboard
        self.openStatusDetail = openStatusDetail
        self.openProviderOverview = openProviderOverview
        self.hoverProviderOverview = hoverProviderOverview
        self.claudeDefaultAccountEnabled = claudeDefaultAccountEnabled
        self.claudeEnabledCustomAccountIDs = claudeEnabledCustomAccountIDs
        self.claudeEnabledAccountMetrics = claudeEnabledAccountMetrics
        self.grokAccounts = grokAccounts
    }

    /// The enabled providers currently shown in the popover.
    private var enabledProviders: Set<ServiceType> {
        Set(snapshots.map(\.service))
    }

    /// Enabled providers that still need setup — drives the first-run checklist.
    /// Keyed on `needsSetup` (a genuine install/auth/data failure), NOT `!isHealthy`:
    /// a working provider whose only blemish is a transient refresh or format-health
    /// *warning* must not keep "Finish setup" pinned open forever. The section
    /// collapses (renders nothing) once no enabled provider has a real setup gap.
    private var providersNeedingSetup: [ProviderReadiness] {
        setupReports.filter { enabledProviders.contains($0.provider) && $0.needsSetup }
    }

    /// Captures *which* tiles the panel shows, not their values. The panel
    /// refreshes periodically; animating on this key means a routine data tick
    /// (a number moving, a countdown ticking) does not re-trigger the tile
    /// transitions — only a structural change (a tile appearing/leaving, a
    /// provider entering/exiting the list) does. Numeric ticks animate
    /// separately via the cards' own `.numericText()` content transitions.
    private struct StructuralKey: Equatable {
        let showsFirstRun: Bool
        let isEmpty: Bool
        let setupProviders: [ServiceType]
        let snapshotIDs: [String]
    }

    private struct ReadinessInputKey: Equatable {
        let providers: [ServiceType]
        let defaultClaudeAccountEnabled: Bool
        let enabledClaudeCustomAccountIDs: [UUID]
        let claudeMetricFreshness: [Bool]
        let enabledGrokAccountIDs: [UUID]
    }

    private var structuralKey: StructuralKey {
        StructuralKey(
            showsFirstRun: onboarding.shouldPresent,
            isEmpty: snapshots.isEmpty,
            setupProviders: providersNeedingSetup.map(\.provider),
            snapshotIDs: snapshots.map(\.id)
        )
    }

    private var readinessInputKey: ReadinessInputKey {
        let now = Date()
        return ReadinessInputKey(
            providers: ServiceType.allCases.filter { enabledProviders.contains($0) },
            defaultClaudeAccountEnabled: claudeDefaultAccountEnabled,
            enabledClaudeCustomAccountIDs: claudeEnabledCustomAccountIDs,
            claudeMetricFreshness: claudeEnabledAccountMetrics.map {
                ProviderReadinessInspector.hasRecentClaudeUsageFetch(metrics: $0, now: now)
            },
            enabledGrokAccountIDs: grokAccounts.filter(\.isEnabled).map(\.id)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if onboarding.shouldPresent {
                firstRunCallout
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            if snapshots.isEmpty {
                emptyState
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            if !providersNeedingSetup.isEmpty {
                setupChecklist
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            VStack(spacing: 8) {
                ForEach(snapshots) { snapshot in
                    ProviderStatusCard(
                        snapshot: snapshot,
                        onHoverChange: hoverProviderOverview.map { change in { change(snapshot, $0) } },
                        onSelect: { openProviderOverview(snapshot) }
                    )
                    .reportPopoverCardFrame(id: snapshot.id)
                    .transition(MeterBarTheme.Motion.popoverTile)
                }
            }
        }
        .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: reduceMotion),
            value: structuralKey
        )
        .task(id: readinessInputKey) {
            await loadSetupReports()
        }
    }

    private var emptyState: some View {
        DashboardTile(padding: .popover) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No sources enabled")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Enable a provider in Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Button("Open Settings") { UsageDashboardWindowController.shared.showSettings(.providers) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    /// First-run/empty-state checklist: per-provider readiness checks with
    /// recovery actions for enabled providers that aren't healthy yet. Collapses
    /// automatically once every enabled provider reports healthy.
    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MeterBarTheme.appAccent)
                Text("Finish setup")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            ReadinessChecklist(
                reports: providersNeedingSetup,
                compact: true,
                recoveryAction: { UsageDashboardWindowController.shared.showSettings(.providers) }
            )
        }
    }

    private var firstRunCallout: some View {
        DashboardTile(padding: .popover) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(MeterBarTheme.appAccent)
                    Text("Welcome to MeterBar")
                        .font(.headline)
                        .fontWeight(.semibold)
                }

                Text("Your usage lives in the menu bar. Start MeterBar automatically when you log in?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Enable") { onboarding.chooseLaunchAtLogin(true) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    Button("Not Now") { onboarding.chooseLaunchAtLogin(false) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Runs the readiness inspector off the main actor (keychain / file / SQLite
    /// I/O) and publishes the reports back for the checklist.
    private func loadSetupReports() async {
        let requestedProviders = enabledProviders
        let defaultAccountEnabled = claudeDefaultAccountEnabled
        let accountMetrics = claudeEnabledAccountMetrics
        let grokProfiles = grokAccounts
        let reports = await Task.detached(priority: .utility) {
            ProviderReadinessInspector.reports(
                providers: requestedProviders,
                claudeDefaultAccountEnabled: defaultAccountEnabled,
                claudeEnabledAccountMetrics: accountMetrics,
                grokAccounts: grokProfiles
            )
        }.value
        guard !Task.isCancelled else { return }
        setupReports = reports
    }
}
