import AppKit
import MeterBarShared
import SwiftUI

private final class CardFrameBox {
  var frames: [String: CGRect] = [:]
}

/// The hover column that is open beside the popover. `make` builds the content
/// for the current `isPresented`, so closing can play the cards' exit before the
/// column is removed.
private struct DetailPresentation {
  let id: String
  /// Distance from the window top to the card that opened it, so the column
  /// top-aligns with that card.
  let topInset: CGFloat
  /// Height of that card, so the glass bridge meets it at its middle.
  let sourceHeight: CGFloat
  let make: (_ isPresented: Bool) -> AnyView
}

struct MenuBarView: View {
  let onContentSizeChange: (NSSize) -> Void

  @StateObject private var dataManager = UsageDataManager.shared
  @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
  @StateObject private var codexCliService = CodexCliLocalService.shared
  @StateObject private var codexAccountStore = CodexAccountStore.shared
  @StateObject private var grokAccountStore = GrokAccountStore.shared
  @StateObject private var openRouterAccountStore = OpenRouterAccountStore.shared
  @StateObject private var cursorService = CursorLocalService.shared
  @StateObject private var openRouterService = OpenRouterService.shared
  @StateObject private var grokService = GrokCLIUsageService.shared
  @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
  @StateObject private var providerVisibility = ProviderVisibilityStore.shared
  @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared
  @StateObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared
  // Only read for the hover panel's seven-day strip. Safe to hold here: the
  // tracker's initializer just rehydrates the cached summary and ledger from
  // disk — observing it never starts a scan.
  @StateObject private var costTracker = CostTracker.shared
  @StateObject private var parseHealthStore = ProviderParseHealthStore.shared

  @State private var contentHeight: CGFloat = 320
  @State private var detail: DetailPresentation?
  /// False while the open hover plays its exit, before `detail` is cleared.
  @State private var detailPresented = false
  /// The open hover's bottom edge, from the window top.
  @State private var detailBottom: CGFloat = 0
  @State private var sourceIsHovered = false
  @State private var detailIsHovered = false
  @State private var dismissTask: Task<Void, Never>?
  @State private var removeTask: Task<Void, Never>?
  @State private var cardFrameBox = CardFrameBox()
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var menuWindow: NSWindow?

  init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
    self.onContentSizeChange = onContentSizeChange
  }

  var body: some View {
    // The popover cards are separate glass surfaces with no container: inside
    // one, the system unions every card closer than the blend distance into a
    // single outlined blob. Only the hover column blends, with its own bridge.
    HStack(alignment: .top, spacing: MenuBarPopoverGeometry.detailGap) {
      if let detail {
        detailColumn(detail)
      }

      mainColumn
        .frame(width: MenuBarPopoverGeometry.width, height: popoverHeight)
        .environment(\.meterBarTileSurface, .glass)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .background(
      MeterBarMenuWindowAccessor { window in
        menuWindow = window
        configureMenuWindow(window)
      }
    )
    .onAppear {
      notifyContentSize()
    }
    .task {
      // The hover strip reads the cached scan. A Claude/Codex-only cache
      // looks complete, so Costs-page backfill never runs and Grok stays
      // empty until the user hits Scan. Kick that backfill when the menu
      // opens instead of making them find the Costs page.
      await costTracker.refreshMissingDaysInBackground()
    }
    .onDisappear {
      resetDetail()
    }
    .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
      guard height > 0, abs(height - contentHeight) > 1 else { return }
      contentHeight = height
      notifyContentSize(height: height)
    }
    .onPreferenceChange(PopoverCardFramesPreferenceKey.self) { frames in
      cardFrameBox.frames = frames
    }
    .onPreferenceChange(DetailBottomPreferenceKey.self) { bottom in
      guard abs(bottom - detailBottom) > 1 else { return }
      detailBottom = bottom
      notifyContentSize()
    }
  }

  private func detailColumn(_ detail: DetailPresentation) -> some View {
    // Blend distance below the 12pt card gap: hover cards stay apart at rest
    // and only melt together while they overlap on the way in, and the bridge
    // melts into the card it overlaps.
    GlassEffectContainer(spacing: MenuBarPopoverGeometry.detailGap) {
      detail.make(detailPresented)
        .overlay(alignment: .topTrailing) {
          detailBridge(for: detail)
        }
    }
      .frame(width: MenuBarPopoverGeometry.detailWidth)
      .frame(
        maxHeight: max(
          MenuBarPopoverGeometry.minimumScrollHeight,
          maximumPopoverHeight - detail.topInset
        ),
        alignment: .top
      )
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: DetailBottomPreferenceKey.self,
            value: detail.topInset + proxy.size.height
          )
        }
      )
      .padding(.top, detail.topInset)
      .onHover { setDetailHovered($0) }
  }

  /// The provider cards the popover draws.
  ///
  /// Lifted out of `mainColumn` so the hover handler can read the same list the
  /// body drew: a Claude/Codex/Grok user with several accounts gets one card per
  /// account, and the detail panel has to know that to caption its chart
  /// honestly — the cost cache has no account dimension, so its figures cover
  /// every account at once.
  private var snapshots: [ProviderSnapshot] {
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
      ))
  }

  private var mainColumn: some View {
    // The header is a floating glass bar over the scroll view, not a strip above
    // it: `safeAreaBar` insets the content by the bar's height and lets the
    // system draw its soft scroll-edge fade where cards slide underneath, in
    // place of the hard rule the old header-plus-Divider stack drew.
    ScrollView {
      VStack(spacing: MeterBarTheme.Spacing.md) {
        PopoverOverviewPanel(
          snapshots: snapshots,
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
          },
          claudeAccounts: claudeAccountStore.accounts,
          claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
          codexAccounts: codexAccountStore.accounts,
          grokAccounts: grokAccountStore.accounts,
          showsRecommendationHint: menuBarDisplayPreferences.showsRecommendationHint,
          showsRoutingLine: true
        )

        DashboardTile(padding: .popover) {
          StayAwakeMenuControl()
        }

        if SessionWakeMenuControl.shouldShow(
          featureEnabled: sessionWakeStore.featureEnabled,
          isOn: sessionWakeStore.isOn,
          canTurnOn: sessionWakeStore.canTurnOn
        ) {
          DashboardTile(padding: .popover) {
            SessionWakeMenuControl()
          }
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
    .safeAreaBar(edge: .top, spacing: 0) {
      popoverHeader
        .frame(height: MenuBarPopoverGeometry.chromeHeight)
    }
    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    .frame(height: scrollHeight + MenuBarPopoverGeometry.chromeHeight)
  }

  private var scrollHeight: CGFloat {
    MenuBarPopoverGeometry.scrollHeight(
      contentHeight: contentHeight,
      maximumHeight: maximumPopoverHeight
    )
  }

  private var popoverHeight: CGFloat {
    MenuBarPopoverGeometry.popoverHeight(
      scrollHeight: scrollHeight,
      maximumHeight: maximumPopoverHeight
    )
  }

  private var maximumPopoverHeight: CGFloat {
    let visibleHeight = menuWindow?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height
      ?? MenuBarPopoverGeometry.fallbackVisibleScreenHeight
    return MenuBarPopoverGeometry.maximumHeight(visibleScreenHeight: visibleHeight)
  }

  /// Reports the popover size to the menu-bar window controller through the same
  /// clamp functions `body` renders with, so the window can never disagree with
  /// its own content.
  private func notifyContentSize(height: CGFloat? = nil) {
    onContentSizeChange(
      MenuBarPopoverGeometry.windowSize(
        popover: MenuBarPopoverGeometry.contentSize(
          contentHeight: height ?? contentHeight,
          maximumHeight: maximumPopoverHeight
        ),
        hasDetail: detail != nil,
        detailBottom: detailBottom,
        maximumHeight: maximumPopoverHeight
      )
    )
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
          Task { await dataManager.refreshForExplicitAction(.manualRefresh) }
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
    resetDetail()
    UsageDashboardWindowController.shared.show()
  }

  private func openStatusDetail() {
    presentDetail(id: PopoverCardID.providerStatus) { _ in
      // The status panel carries its own shell and fills the height it is
      // offered, so it takes its natural height here.
      AnyView(MenuBarStatusDetailContent().fixedSize(horizontal: false, vertical: true))
    }
  }

  private func openProviderDetail(_ snapshot: ProviderSnapshot) {
    // Bucketed here, at hover time, rather than inside the panel: the panel's
    // `body` re-runs on every hover tick, and it is hosted in tests that must
    // not stand up the cost scanner.
    let series = ProviderDailyUsageSeries.make(
      service: snapshot.service,
      dailyUsage: costTracker.costSummary?.dailyUsage ?? [],
      ledger: costTracker.usageLedger,
      accountCount: accountCardCount(for: snapshot.service)
    )
    let isRefreshing = costTracker.isRefreshingMissingDays || costTracker.isScanning
    let scanDate = costTracker.lastScanDate
    presentDetail(id: snapshot.id) { isPresented in
      AnyView(
        MenuBarProviderDetailContent(
          snapshot: snapshot,
          dailyUsage: series,
          isRefreshingUsage: isRefreshing,
          costScanDate: scanDate,
          isPresented: isPresented
        )
      )
    }
  }

  /// How many cards the popover is currently drawing for one provider. Anything
  /// above one means the panel's figures are the provider's total, not this
  /// card's account, which the chart says out loud rather than implying.
  /// Delegates to `accountCardCount(for:)` so a shared-branding sub-pool card
  /// (Cursor's Grok Bot) never inflates this into a false multi-account claim.
  private func accountCardCount(for service: ServiceType) -> Int {
    snapshots.accountCardCount(for: service)
  }

  /// Provider-card hover owns the hover column together with the column's own
  /// hover region. Leaving both closes it; crossing the small gap between them
  /// is covered by a short deferred dismiss.
  private func hoverProviderDetailChanged(_ snapshot: ProviderSnapshot, isHovered: Bool) {
    sourceIsHovered = isHovered
    if isHovered, !(detail?.id == snapshot.id && detailPresented) {
      openProviderDetail(snapshot)
    }
    reconcileDetailDismissal()
  }

  /// Hover-driven open for the header status cluster (same non-toggling rule).
  private func hoverOpenStatusDetail() {
    guard !(detail?.id == PopoverCardID.providerStatus && detailPresented) else { return }
    openStatusDetail()
  }

  /// A short glass neck from the hover column across the gap to the card that
  /// opened it, so the hover reads as grown out of that card.
  private func detailBridge(for detail: DetailPresentation) -> some View {
    let height = min(MenuBarPopoverGeometry.bridgeHeight, max(0, detail.sourceHeight - 24))
    return Color.clear
      .frame(width: MenuBarPopoverGeometry.bridgeWidth, height: height)
      .meterBarGlassCard(cornerRadius: height / 2)
      .scaleEffect(x: detailPresented ? 1 : 0.2, y: 1, anchor: .trailing)
      .opacity(detailPresented ? 1 : 0)
      .offset(
        x: MenuBarPopoverGeometry.detailGap,
        y: max(0, detail.sourceHeight / 2 - height / 2)
      )
      .animation(
        MeterBarTheme.Motion.resolve(.smooth(duration: 0.2), reduceMotion: reduceMotion),
        value: detailPresented
      )
      .allowsHitTesting(false)
  }

  private func setDetailHovered(_ isHovered: Bool) {
    detailIsHovered = isHovered
    reconcileDetailDismissal()
  }

  private func reconcileDetailDismissal() {
    dismissTask?.cancel()
    dismissTask = nil
    guard detailPresented, !sourceIsHovered, !detailIsHovered else { return }
    dismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 140_000_000)
      guard !Task.isCancelled, !sourceIsHovered, !detailIsHovered else { return }
      closeDetail()
    }
  }

  /// Presents (or toggles off) the hover column, top-aligned with the popover
  /// card that opened it.
  private func presentDetail(id: String, make: @escaping (Bool) -> AnyView) {
    if detail?.id == id, detailPresented {
      closeDetail()
      return
    }

    removeTask?.cancel()
    removeTask = nil
    let source = cardFrameBox.frames[id]
    detail = DetailPresentation(
      id: id,
      topInset: max(0, source?.minY ?? 0),
      sourceHeight: source?.height ?? 0,
      make: make
    )
    detailPresented = true
    notifyContentSize()
  }

  /// Plays the cards' exit, then drops the column and gives the width back.
  private func closeDetail() {
    detailPresented = false
    removeTask?.cancel()
    removeTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      detail = nil
      detailBottom = 0
      notifyContentSize()
    }
  }

  private func resetDetail() {
    dismissTask?.cancel()
    removeTask?.cancel()
    detail = nil
    detailPresented = false
    detailBottom = 0
    sourceIsHovered = false
    detailIsHovered = false
    notifyContentSize()
  }

  private func configureMenuWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
  }
}

private enum MenuBarOverlayIcons {
  static let dashboard = "rectangle.split.2x1"
}

private struct DetailBottomPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
