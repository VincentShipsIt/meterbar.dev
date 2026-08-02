import AppKit
import MeterBarShared
import SwiftUI

private final class CardFrameBox {
  var frames: [String: CGRect] = [:]
}

struct MenuBarView: View {
  let onContentSizeChange: (NSSize) -> Void

  @StateObject private var dataManager = UsageDataManager.shared
  @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
  @StateObject private var codexCliService = CodexCliLocalService.shared
  @StateObject private var codexAccountStore = CodexAccountStore.shared
  @StateObject private var grokAccountStore = GrokAccountStore.shared
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
    .frame(width: MenuBarPopoverGeometry.width, height: popoverHeight)
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
                codexAccountAccess: codexCliService.accountAccess,
                grokAccounts: grokAccountStore.accounts,
                grokAccountMetrics: dataManager.grokAccountMetrics,
                claudeAccounts: claudeAccountStore.accounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                fableSessions: fableSessionTracker.sessions,
                enabledServices: providerVisibility.enabledServices,
                claudeAccountStates: dataManager.claudeCodeAccountStates,
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
            },
            grokAccounts: grokAccountStore.accounts
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
      MenuBarPopoverGeometry.contentSize(
        contentHeight: height ?? contentHeight,
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

private struct MenuContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
