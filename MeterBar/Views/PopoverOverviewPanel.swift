import Foundation
import MeterBarShared
import SwiftUI

/// The popover's scrolling body: first-run callout, empty state, and the
/// provider card stack. Connection failures share a first "Needs attention"
/// card and one hover with all affected providers; quota exhaustion and usage
/// warnings stay on their provider cards.
struct PopoverOverviewPanel: View {
    let snapshots: [ProviderSnapshot]
    let openDashboard: () -> Void
    // Provider status lives in the footer, so the panel no longer
    // renders a status card; `openStatusDetail` is retained for source/test compat.
    let openStatusDetail: () -> Void
    let openProviderOverview: (ProviderSnapshot) -> Void
    /// Hover-driven open for a provider card (opens its detail panel on pointer
    /// enter). Optional so existing/test call sites stay valid.
    var hoverProviderOverview: ((ProviderSnapshot, Bool) -> Void)?
    var openProviderErrors: (([ProviderSnapshot]) -> Void)?
    var hoverProviderErrors: (([ProviderSnapshot], Bool) -> Void)?
    let claudeDefaultAccountEnabled: Bool
    let claudeEnabledCustomAccountIDs: [UUID]
    let claudeEnabledAccountMetrics: [UsageMetrics]
    let claudeAccounts: [ClaudeCodeAccount]
    let claudeAccountMetrics: [UUID: UsageMetrics]
    let codexAccounts: [CodexAccount]
    let grokAccounts: [GrokAccount]
    /// Opt-in one-line "what to use next" hint. Defaults to off so the popover
    /// keeps its pre-feature layout; the full ranking lives in the dashboard.
    let showsRecommendationHint: Bool
    /// One-line routing recommendation at the top. Off by default so previews
    /// and tests never read the shared routing files.
    let showsRoutingLine: Bool

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
        openProviderErrors: (([ProviderSnapshot]) -> Void)? = nil,
        hoverProviderErrors: (([ProviderSnapshot], Bool) -> Void)? = nil,
        claudeDefaultAccountEnabled: Bool = true,
        claudeEnabledCustomAccountIDs: [UUID] = [],
        claudeEnabledAccountMetrics: [UsageMetrics] = [],
        claudeAccounts: [ClaudeCodeAccount] = [.defaultAccount],
        claudeAccountMetrics: [UUID: UsageMetrics] = [:],
        codexAccounts: [CodexAccount] = [.defaultAccount],
        grokAccounts: [GrokAccount] = [.defaultAccount],
        showsRecommendationHint: Bool = false,
        showsRoutingLine: Bool = false
    ) {
        self.snapshots = snapshots
        self.openDashboard = openDashboard
        self.openStatusDetail = openStatusDetail
        self.openProviderOverview = openProviderOverview
        self.hoverProviderOverview = hoverProviderOverview
        self.openProviderErrors = openProviderErrors
        self.hoverProviderErrors = hoverProviderErrors
        self.claudeDefaultAccountEnabled = claudeDefaultAccountEnabled
        self.claudeEnabledCustomAccountIDs = claudeEnabledCustomAccountIDs
        self.claudeEnabledAccountMetrics = claudeEnabledAccountMetrics
        self.claudeAccounts = claudeAccounts
        self.claudeAccountMetrics = claudeAccountMetrics
        self.codexAccounts = codexAccounts
        self.grokAccounts = grokAccounts
        self.showsRecommendationHint = showsRecommendationHint
        self.showsRoutingLine = showsRoutingLine
    }

    /// The enabled providers currently shown in the popover.
    private var enabledProviders: Set<ServiceType> {
        Set(snapshots.map(\.service))
    }

    static func errorSnapshots(in snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.filter { snapshot in
            if snapshot.issueLevel == .fail { return true }
            switch snapshot.authNotice {
            case .loginRequired, .attention, .notConnected: return true
            case .none, .stale: return false
            }
        }
    }

    static func cardStateKey(_ snapshots: [ProviderSnapshot]) -> [String] {
        snapshots.map { "\($0.id)|\($0.hasMetrics)|\($0.emptyDetail)" }
    }

    /// The cards the stack draws, each carrying its readiness issues.

    private var visibleSnapshots: [ProviderSnapshot] {
        Self.attachingIssues(to: snapshots, from: setupReports)
    }

    private var errorSnapshots: [ProviderSnapshot] { Self.errorSnapshots(in: visibleSnapshots) }

    private var normalSnapshots: [ProviderSnapshot] {
        let errors = Set(errorSnapshots.map(\.id))
        return visibleSnapshots.filter { !errors.contains($0.id) }
    }

    /// Hands each card the failing and warning checks that apply to it: an
    /// account report to that account's card, a provider-wide report to every
    /// card of the provider. Passing checks are dropped, since they need no
    /// attention, and a check two reports state the same way is listed once.
    ///
    /// When a provider has account reports, its provider-wide report is only
    /// their rollup and is skipped, as the old setup checklist did; the Cursor
    /// sign-in beside Grok is provider-wide but its own source, so it stays.
    static func attachingIssues(
        to snapshots: [ProviderSnapshot],
        from reports: [ProviderReadiness]
    ) -> [ProviderSnapshot] {
        let accountScopedProviders = Set(reports.filter(\.identity.isAccountScoped).map(\.provider))
        return snapshots.map { snapshot in
            var annotated = snapshot
            annotated.issues = reports
                .filter { report in
                    guard report.provider == snapshot.service else { return false }
                    if let accountID = report.identity.accountID {
                        return accountID == snapshot.accountID
                    }
                    return report.identity == .cursorSubscription
                        || !accountScopedProviders.contains(report.provider)
                }
                .flatMap(\.checks)
                .filter { $0.level != .pass }
                .uniqued()
            return annotated
        }
    }

    /// Captures *which* tiles the panel shows, not their values. The panel
    /// refreshes periodically; animating on this key means a routine data tick
    /// (a number moving, a countdown ticking) does not re-trigger the tile
    /// transitions — only a structural change (a tile appearing/leaving, a
    /// provider entering/exiting the list) does. Numeric ticks animate
    /// separately via the cards' own `.numericText()` content transitions.
    private struct StructuralKey: Equatable {
        let showsFirstRun: Bool
        let showsRecommendationHint: Bool
        let isEmpty: Bool
        let issueCards: [String]
        let snapshotIDs: [String]
    }

    private struct ReadinessInputKey: Equatable {
        let providers: [ServiceType]
        let defaultClaudeAccountEnabled: Bool
        let enabledClaudeCustomAccountIDs: [UUID]
        let claudeMetricFreshness: [Bool]
        let enabledCodexAccountIDs: [UUID]
        let enabledGrokAccountIDs: [UUID]
        let cardStates: [String]
    }

    private var structuralKey: StructuralKey {
        StructuralKey(
            showsFirstRun: onboarding.shouldPresent,
            showsRecommendationHint: showsRecommendationHint,
            isEmpty: snapshots.isEmpty,
            issueCards: errorSnapshots.map(\.id),
            snapshotIDs: visibleSnapshots.map(\.id)
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
            enabledCodexAccountIDs: codexAccounts.filter(\.isEnabled).map(\.id),
            enabledGrokAccountIDs: grokAccounts.filter(\.isEnabled).map(\.id),
            cardStates: Self.cardStateKey(snapshots)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuBarPopoverGeometry.cardGap) {
            if !errorSnapshots.isEmpty {
                errorGroup
            }
            if showsRoutingLine {
                PopoverRoutingLineView()
            }

            if onboarding.shouldPresent {
                firstRunCallout
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            if snapshots.isEmpty {
                emptyState
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            if showsRecommendationHint {
                recommendationHint
                    .transition(MeterBarTheme.Motion.popoverTile)
            }

            VStack(spacing: MenuBarPopoverGeometry.cardGap) {
                ForEach(normalSnapshots) { snapshot in
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

    private var errorGroup: some View {
        let errors = errorSnapshots
        return Button {
            openProviderErrors?(errors)
        } label: {
            DashboardTile(padding: .popover) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MeterBarTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Needs attention").font(.subheadline).fontWeight(.semibold)
                        Text(errors.map(\.title).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text("\(errors.count)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Needs attention: \(errors.map(\.title).joined(separator: ", "))")
        .accessibilityHint("Show all provider connection errors")
        .onHover { hoverProviderErrors?(errors, $0) }
        .reportPopoverCardFrame(id: PopoverCardID.providerErrors)
    }

    /// The opt-in one-line "what to use next" row.
    ///
    /// Deliberately the same sentence the dashboard card leads with — the popover
    /// is the glanceable copy of that ranking, not a second opinion. Ticks on the
    /// shared reset-countdown schedule so its countdown, and the ranking that
    /// weighs it, stay current without a clock of its own. Renders nothing when
    /// nothing is rankable rather than guessing a pick.
    @ViewBuilder private var recommendationHint: some View {
        TimelineView(
            .periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)
        ) { timeline in
            let recommendation = snapshots.headroomRecommendation(now: timeline.date)
            if let headline = recommendation.headline, let top = recommendation.top {
                DashboardTile(padding: .popover) {
                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MeterBarTheme.accent(for: top.service))
                            .accessibilityHidden(true)

                        Text(headline)
                            .font(.caption)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Recommended next")
                    .accessibilityValue(top.summary)
                }
            }
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
        let claudeProfiles = claudeAccounts
        let claudeMetricsByID = claudeAccountMetrics
        let codexProfiles = codexAccounts
        let grokProfiles = grokAccounts
        let reports = await Task.detached(priority: .utility) {
            ProviderReadinessInspector.reports(
                providers: requestedProviders,
                claudeAccounts: claudeProfiles,
                claudeAccountMetrics: claudeMetricsByID,
                claudeDefaultAccountEnabled: defaultAccountEnabled,
                claudeEnabledAccountMetrics: accountMetrics,
                codexAccounts: codexProfiles,
                grokAccounts: grokProfiles
            )
        }.value
        guard !Task.isCancelled else { return }
        setupReports = reports
    }
}

private extension Array where Element == ReadinessCheck {
    func uniqued() -> [ReadinessCheck] {
        var seen = Set<String>()
        return filter { seen.insert("\($0.id)\u{1F}\($0.detail)").inserted }
    }
}
