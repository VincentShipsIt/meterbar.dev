import AppKit
import MeterBarShared
import SwiftUI

private final class CardFrameBox {
  var frames: [String: CGRect] = [:]
}

struct MenuBarView: View {
  private let popoverWidth: CGFloat = 390
  private let minPopoverHeight: CGFloat = 180
  private let chromeHeight: CGFloat = 41
  private let screenPadding: CGFloat = 8

  let onContentSizeChange: (NSSize) -> Void

  @StateObject private var dataManager = UsageDataManager.shared
  @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
  @StateObject private var codexCliService = CodexCliLocalService.shared
  @StateObject private var codexAccountStore = CodexAccountStore.shared
  @StateObject private var cursorService = CursorLocalService.shared
  @StateObject private var openRouterService = OpenRouterService.shared
  @StateObject private var grokService = GrokCLIUsageService.shared
  @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
  @StateObject private var fableSessionTracker = ClaudeFableSessionTracker.shared
  @StateObject private var providerVisibility = ProviderVisibilityStore.shared
  @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared

  @State private var contentHeight: CGFloat = 320
  @State private var expandedDetailID: String?
  @State private var cardFrameBox = CardFrameBox()
  @State private var menuWindow: NSWindow?

  init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
    self.onContentSizeChange = onContentSizeChange
  }

  var body: some View {
    mainColumn
    .frame(width: popoverWidth, height: popoverHeight)
    .background(MeterBarTheme.Surface.chrome(radius: MeterBarTheme.companionShellRadius))
    .clipShape(RoundedRectangle(cornerRadius: MeterBarTheme.companionShellRadius, style: .continuous))
    .background(
      MeterBarMenuWindowAccessor { window in
        menuWindow = window
        configureMenuWindow(window)
      }
    )
    .onAppear {
      notifyContentSize()
    }
    .onDisappear {
      expandedDetailID = nil
      MeterBarMenuDetailPanel.shared.dismiss()
    }
    .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
      guard height > 0, abs(height - contentHeight) > 1 else { return }
      contentHeight = height
      notifyContentSize(height: height)
    }
    .onPreferenceChange(PopoverCardFramesPreferenceKey.self) { frames in
      cardFrameBox.frames = frames
    }
  }

  private var mainColumn: some View {
    VStack(spacing: 0) {
      popoverHeader

      Divider()

      ScrollView {
        VStack(spacing: 10) {
          PopoverOverviewPanel(
            snapshots: ProviderSnapshotBuilder.snapshots(
              ProviderSnapshotBuilder.Input(
                metrics: dataManager.metrics,
                codexAccounts: codexAccountStore.accounts,
                codexAccountMetrics: dataManager.codexAccountMetrics,
                claudeAccounts: claudeAccountStore.accounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                fableSessions: fableSessionTracker.sessions,
                enabledServices: providerVisibility.enabledServices,
                claudeCodeHasAccess: claudeCodeService.hasAccess,
                codexCliHasAccess: codexCliService.hasAccess,
                cursorHasAccess: cursorService.hasAccess,
                openRouterHasAccess: openRouterService.hasAccess,
                grokHasAccess: grokService.hasAccess
              )),
            openDashboard: openDashboard,
            openStatusDetail: openStatusDetail,
            openProviderOverview: openProviderDetail,
            hoverProviderOverview: hoverProviderDetailChanged,
            claudeDefaultAccountEnabled: claudeAccountStore.defaultAccountIsEnabled,
            claudeEnabledCustomAccountIDs: claudeAccountStore.enabledAccounts
              .filter { !$0.isDefault }
              .map(\.id),
            claudeEnabledAccountMetrics: claudeAccountStore.enabledAccounts.compactMap {
              dataManager.claudeCodeAccountMetrics[$0.id]
            }
          )

          if SessionWakeMenuControl.shouldShow(
            featureEnabled: sessionWakeStore.featureEnabled,
            isOn: sessionWakeStore.isOn,
            canTurnOn: sessionWakeStore.canTurnOn
          ) {
            Divider()
            SessionWakeMenuControl()
          }
        }
        .padding(MeterBarTheme.Spacing.md)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: MenuContentHeightPreferenceKey.self,
              value: proxy.size.height
            )
          }
        )
      }
      .scrollIndicators(.hidden)
      .scrollContentBackground(.hidden)
      .frame(height: scrollHeight)
    }
  }

  private var scrollHeight: CGFloat {
    min(max(80, contentHeight), maximumPopoverHeight - chromeHeight)
  }

  private var popoverHeight: CGFloat {
    min(max(chromeHeight + scrollHeight, minPopoverHeight), maximumPopoverHeight)
  }

  private var maximumPopoverHeight: CGFloat {
    let visibleHeight = menuWindow?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height
      ?? 720
    return max(minPopoverHeight, min(760, visibleHeight - (screenPadding * 2)))
  }

  private func notifyContentSize(height: CGFloat? = nil) {
    let measuredHeight = height ?? contentHeight
    let maxHeight = maximumPopoverHeight
    let targetScrollHeight = min(max(80, measuredHeight), maxHeight - chromeHeight)
    let targetHeight = min(
      max(chromeHeight + targetScrollHeight, minPopoverHeight), maxHeight)
    onContentSizeChange(NSSize(width: popoverWidth, height: targetHeight))
  }

  private var popoverHeader: some View {
    HStack(spacing: 8) {
      PopoverHeaderStatusDots(
        openDetail: openStatusDetail,
        hoverOpenDetail: hoverOpenStatusDetail
      )

      Spacer()

      // Dashboard + Refresh fused into one glass capsule (were two separate glass
      // circles) so the header actions read as a single pill, matching the
      // status-dots pill on the left.
      HStack(spacing: 2) {
        Button(action: openDashboard) {
          Image(systemName: MenuBarOverlayIcons.dashboard)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help("Open Usage Dashboard")
        .accessibilityLabel("Open Dashboard")

        Button {
          Task { await dataManager.refreshAll() }
        } label: {
          RefreshingIcon(isRefreshing: dataManager.isLoading)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help(dataManager.isLoading ? "Refreshing usage" : "Refresh usage (⌘R)")
        .accessibilityLabel("Refresh")
        .accessibilityValue(dataManager.isLoading ? "Refreshing" : "")
        .meterBarRefreshShortcut()
        .disabled(dataManager.isLoading)
      }
      .glassEffect(.regular.interactive(), in: .capsule)
    }
    .font(.body)
    .padding(.horizontal, MeterBarTheme.Spacing.lg)
    .padding(.vertical, MeterBarTheme.Spacing.sm)
  }

  private func openDashboard() {
    expandedDetailID = nil
    MeterBarMenuDetailPanel.shared.dismiss()
    UsageDashboardWindowController.shared.show()
  }

  private func openStatusDetail() {
    presentDetail(
      id: PopoverCardID.providerStatus,
      content: AnyView(MenuBarStatusDetailContent())
    )
  }

  private func openProviderDetail(_ snapshot: ProviderSnapshot) {
    presentDetail(
      id: snapshot.id,
      content: AnyView(MenuBarProviderDetailContent(snapshot: snapshot))
    )
  }

  /// Provider-card hover owns the detail panel together with the detail panel's
  /// own hover region. Leaving both closes it; crossing the inter-panel gap is
  /// covered by the detail panel's short deferred-dismiss window.
  private func hoverProviderDetailChanged(_ snapshot: ProviderSnapshot, isHovered: Bool) {
    MeterBarMenuDetailPanel.shared.setSourceHovered(isHovered) {
      guard expandedDetailID == snapshot.id else { return }
      expandedDetailID = nil
    }

    guard isHovered, expandedDetailID != snapshot.id else { return }
    openProviderDetail(snapshot)
  }

  /// Hover-driven open for the header status cluster (same non-toggling rule).
  private func hoverOpenStatusDetail() {
    guard expandedDetailID != PopoverCardID.providerStatus else { return }
    openStatusDetail()
  }

  /// Presents (or toggles off) the secondary detail card, top-aligned with the
  /// popover card that opened it.
  private func presentDetail(id: String, content: AnyView) {
    if expandedDetailID == id {
      expandedDetailID = nil
      MeterBarMenuDetailPanel.shared.dismiss()
      return
    }

    guard let menuWindow else { return }
    expandedDetailID = id
    MeterBarMenuDetailPanel.shared.present(
      anchor: menuWindow,
      content: content,
      preferredTopY: screenTopY(forCardID: id)
    )
  }

  /// Converts a card's SwiftUI global frame (top-left origin, window space)
  /// into the card top's AppKit screen Y so the detail panel can align to it.
  private func screenTopY(forCardID id: String) -> CGFloat? {
    guard let menuWindow, let frame = cardFrameBox.frames[id] else { return nil }
    return menuWindow.frame.maxY - frame.minY
  }

  private func configureMenuWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
  }
}

private enum MenuBarOverlayIcons {
  static let dashboard = "rectangle.split.2x1"
}

/// The provider-status indicator, promoted from a full popover card into the top
/// bar: just the per-provider dots in a glass pill (matching the header's other
/// glass controls). Tap — or hover — to open the status detail panel.
private struct PopoverHeaderStatusDots: View {
  @StateObject private var statusMonitor = ProviderStatusMonitor.shared
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  let openDetail: () -> Void
  var hoverOpenDetail: (() -> Void)?

  private var summaryText: String {
    let issues = ServiceType.allCases
      .compactMap { statusMonitor.reports[$0] }
      .filter(\.hasIssue)
      .count
    if issues == 0 { return "All provider pages operational" }
    return issues == 1 ? "1 provider needs attention" : "\(issues) providers need attention"
  }

  var body: some View {
    Button(action: openDetail) {
      HStack(spacing: 5) {
        ForEach(ServiceType.allCases) { service in
          let indicator = statusMonitor.reports[service]?.summary.indicator ?? .unknown
          Circle()
            .fill(indicator.tint)
            .frame(width: 7, height: 7)
            .help(service.statusPageDisplayName)
            .animation(
              MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion),
              value: indicator
            )
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .help("Provider status")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Provider status")
    .accessibilityValue(summaryText)
    .accessibilityHint("Show provider status details")
    .onHover { if $0 { hoverOpenDetail?() } }
    .task { await statusMonitor.refreshAllIfNeeded() }
  }
}

// MARK: - Overview panel

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
    claudeEnabledAccountMetrics: [UsageMetrics] = []
  ) {
    self.snapshots = snapshots
    self.openDashboard = openDashboard
    self.openStatusDetail = openStatusDetail
    self.openProviderOverview = openProviderOverview
    self.hoverProviderOverview = hoverProviderOverview
    self.claudeDefaultAccountEnabled = claudeDefaultAccountEnabled
    self.claudeEnabledCustomAccountIDs = claudeEnabledCustomAccountIDs
    self.claudeEnabledAccountMetrics = claudeEnabledAccountMetrics
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
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if onboarding.shouldPresent {
        firstRunCallout
          .transition(MeterBarTheme.Motion.popoverTile)
      }

      if snapshots.isEmpty {
        DashboardTile(padding: 12) {
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
    DashboardTile(padding: 12) {
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
    let reports = await Task.detached(priority: .utility) {
      ProviderReadinessInspector.reports(
        providers: requestedProviders,
        claudeDefaultAccountEnabled: defaultAccountEnabled,
        claudeEnabledAccountMetrics: accountMetrics
      )
    }.value
    guard !Task.isCancelled else { return }
    setupReports = reports
  }
}

// Non-private so the shared card shell can be rendered in both usage states by
// `LiquidGlassP1RegressionTests`.
struct ProviderStatusCard: View {
  let snapshot: ProviderSnapshot
  var onSelect: (() -> Void)?
  var onHoverChange: ((Bool) -> Void)?

  @ObservedObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @StateObject private var codexService = CodexCliLocalService.shared
  @StateObject private var codexAccounts = CodexAccountStore.shared
  @StateObject private var dataManager = UsageDataManager.shared
  @State private var isCodexAuthenticated = false
  @State private var isConsumingResetCredit = false
  @State private var didConsumeResetCredit = false
  @State private var showingResetCreditConfirmation = false
  @State private var resetCreditAlertTitle = "Couldn't use reset credit"
  @State private var resetCreditAlertMessage: String?

  init(
    snapshot: ProviderSnapshot,
    onHoverChange: ((Bool) -> Void)? = nil,
    onSelect: (() -> Void)? = nil
  ) {
    self.snapshot = snapshot
    self.onHoverChange = onHoverChange
    self.onSelect = onSelect
  }

  private var statusColor: Color {
    snapshot.band?.color ?? .secondary
  }

  private var statusText: String {
    snapshot.band?.shortLabel ?? "Offline"
  }

  /// Cards without usage data and exhausted cards are terminal summaries. A
  /// login/waiting card has no quota detail to reveal, while an exhausted card
  /// already shows its only actionable reset information inline.
  var allowsDetailNavigation: Bool {
    onSelect != nil && snapshot.hasMetrics && !snapshot.hasExhaustedLimit
  }

  var body: some View {
    selectableCard
      .providerCardContextMenu(ProviderCardCommands.standard(snapshot: snapshot))
      .task(id: snapshot.updatedAt) {
        await refreshCodexAuthenticationState()
      }
      .confirmationDialog(
        "Use a Codex reset credit?",
        isPresented: $showingResetCreditConfirmation,
        titleVisibility: .visible
      ) {
        Button("Use Reset Credit") { consumeResetCredit() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This spends one of your finite Codex reset credits and resets the active blocked usage window. " +
            "The action cannot be undone."
        )
      }
      .alert(
        resetCreditAlertTitle,
        isPresented: Binding(
          get: { resetCreditAlertMessage != nil },
          set: { if !$0 { resetCreditAlertMessage = nil } }
        )
      ) {
        Button("OK") { resetCreditAlertMessage = nil }
      } message: {
        Text(resetCreditAlertMessage ?? "")
      }
  }

  @ViewBuilder private var selectableCard: some View {
    if let onSelect, allowsDetailNavigation {
      Button(action: onSelect) {
        cardContent
      }
      .buttonStyle(ProviderCardButtonStyle())
      .accessibilityHint("Open \(snapshot.title) provider details")
      .onHover { onHoverChange?($0) }
    } else {
      cardContent
    }
  }

  /// Chevron shown only when the card opens a detail panel, so "clickable" is
  /// visible instead of relying on an accessibilityHint alone.
  @ViewBuilder private var disclosureChevron: some View {
    if allowsDetailNavigation {
      CardDisclosureChevron()
    }
  }

  private var cardContent: some View {
    DashboardTile(padding: 11) {
      cardBody
    }
    .contentShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
  }

  @ViewBuilder private var cardBody: some View {
    if !snapshot.hasMetrics {
      offlineRow
    } else if snapshot.hasExhaustedWeeklyLimit {
      weeklyExhaustedRow
    } else {
      expandedCardBody
    }
  }

  /// Logged-out/no-data providers are terminal status rows. Recovery belongs in
  /// Settings; the popover only needs to say that this profile is offline.
  private var offlineRow: some View {
    HStack(spacing: 7) {
      ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
      Text(snapshot.title)
        .font(.subheadline)
        .fontWeight(.semibold)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text("Offline")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
    }
  }

  /// A weekly block makes every shorter/model-specific gauge non-actionable.
  /// Keep the shared card surface, but collapse its content to the provider and
  /// the one reset that can restore service.
  private var weeklyExhaustedRow: some View {
    TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
      let blockingWindow = BlockingLimitResetCounter.selectBlockingWindow(snapshot.resetWindows, now: timeline.date)
      let title = BlockingLimitResetCounter.titleText(for: blockingWindow, in: snapshot.resetWindows)
      let counter = BlockingLimitResetCounter.counterText(
        for: blockingWindow,
        now: timeline.date,
        format: menuBarDisplayPreferences.resetTimeFormat
      )

      HStack(spacing: 7) {
        ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
        Text(snapshot.title)
          .font(.subheadline)
          .fontWeight(.semibold)
          .lineLimit(1)

        Spacer(minLength: 8)

        Text(statusText)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundColor(statusColor)

        Label("\(title) \(counter)", systemImage: "hourglass")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundColor(snapshot.accentColor)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .numericRefreshTransition(value: counter, reduceMotion: reduceMotion)

        if showsResetCreditAction {
          Button {
            showingResetCreditConfirmation = true
          } label: {
            Image(systemName: "arrow.clockwise.circle.fill")
          }
          .buttonStyle(.borderless)
          .help("Use a Codex reset credit")
          .disabled(isConsumingResetCredit)
        }
      }
    }
  }

  private var expandedCardBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        ProviderLogoView(kind: snapshot.logoKind, size: 17, foregroundColor: snapshot.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(snapshot.title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
          Text(updatedText)
            .font(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        Text(statusText)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundColor(statusColor)

        disclosureChevron
      }

      if snapshot.hasExhaustedLimit {
        BlockingLimitResetCounter(
          windows: snapshot.resetWindows,
          accentColor: snapshot.accentColor,
          format: menuBarDisplayPreferences.resetTimeFormat
        )
      } else {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(snapshot.limits) { limit in
            LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .compact)
          }
        }
      }

      fableActivitySection

      let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
      if badges.hasContent {
        badges
      }

      if showsResetCreditAction {
        Divider()
        resetCreditButton
      }
    }
  }

  @ViewBuilder private var fableActivitySection: some View {
    if let fableActivity = snapshot.fableActivity {
      Divider()
      fableActivityRow(fableActivity)
    }
  }

  private func fableActivityRow(_ activity: FableSessionCardActivity) -> some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let status = activity.status(now: context.date)

      HStack(spacing: 7) {
        Label("Fable 5", systemImage: "sparkles")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        switch status {
        case .active:
          Label("Active", systemImage: "circle.fill")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(MeterBarTheme.success)
        case .recent:
          if let lastObservedAt = activity.session?.lastObservedAt {
            HStack(spacing: 3) {
              Text("Last seen")
              Text(lastObservedAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
        case .noActivity:
          Text("No activity")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(fableActivityAccessibilityLabel(activity, status: status))
    }
  }

  private func fableActivityAccessibilityLabel(
    _ activity: FableSessionCardActivity,
    status: FableSessionCardActivity.Status
  ) -> String {
    switch status {
    case .active:
      return "Fable 5, active"
    case .recent:
      guard let lastObservedAt = activity.session?.lastObservedAt else {
        return "Fable 5, recent activity"
      }
      return "Fable 5, last seen \(lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
    case .noActivity:
      return "Fable 5, no activity"
    }
  }

  private var resetCreditButton: some View {
    Button {
      showingResetCreditConfirmation = true
    } label: {
      HStack(spacing: 6) {
        if isConsumingResetCredit {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise.circle.fill")
        }
        Text(isConsumingResetCredit ? "Using reset credit…" : "Use reset credit")
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .disabled(isConsumingResetCredit)
  }

  private var updatedText: String {
    guard let updatedAt = snapshot.updatedAt else { return "No data" }
    return "Updated \(UsageFormat.relative(updatedAt))"
  }

  private var showsResetCreditAction: Bool {
    guard snapshot.service == .codexCli, !didConsumeResetCredit else { return false }
    return CodexResetCreditEligibility.isEligible(
      isBlocked: snapshot.hasExhaustedLimit,
      availableCredits: snapshot.resetCreditsAvailable,
      isAuthenticated: isCodexAuthenticated
    )
  }

  private var codexAccount: CodexAccount? {
    guard snapshot.service == .codexCli, let accountID = snapshot.accountID else { return nil }
    return codexAccounts.accounts.first { $0.id == accountID }
  }

  private func refreshCodexAuthenticationState() async {
    guard let codexAccount else {
      isCodexAuthenticated = false
      return
    }
    isCodexAuthenticated = await codexService.canAccess(account: codexAccount)
  }

  private func consumeResetCredit() {
    guard let codexAccount, !isConsumingResetCredit else { return }
    isConsumingResetCredit = true

    Task {
      do {
        let result = try await codexService.consumeResetCredit(account: codexAccount)
        didConsumeResetCredit = true
        if let refreshedMetrics = result.refreshedMetrics {
          dataManager.applyCodexResetCreditRefresh(refreshedMetrics, accountID: codexAccount.id)
        }
        if let refreshError = result.usageRefreshErrorDescription {
          resetCreditAlertTitle = "Reset credit used"
          resetCreditAlertMessage =
            "The credit was used, but usage could not refresh (\(refreshError)). Do not retry; refresh later."
        }
      } catch {
        resetCreditAlertTitle = "Couldn't use reset credit"
        resetCreditAlertMessage = error.localizedDescription
      }
      isConsumingResetCredit = false
    }
  }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

// MARK: - Card frame tracking

/// IDs for popover cards that are not provider snapshots.
enum PopoverCardID {
  static let providerStatus = "popover-provider-status"
}

/// Live frames (SwiftUI global space) of the popover cards, keyed by card ID,
/// so the secondary detail panel can top-align with the clicked card.
struct PopoverCardFramesPreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}

extension View {
  func reportPopoverCardFrame(id: String) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: PopoverCardFramesPreferenceKey.self,
          value: [id: proxy.frame(in: .global)]
        )
      }
    )
  }
}
