import AppKit
import MeterBarShared
import SwiftUI

struct MenuBarView: View {
  private let popoverWidth: CGFloat = 390
  private let minPopoverHeight: CGFloat = 180
  private let chromeHeight: CGFloat = 41
  private let screenPadding: CGFloat = 8

  let onContentSizeChange: (NSSize) -> Void

  @StateObject private var dataManager = UsageDataManager.shared
  @StateObject private var claudeCodeService = ClaudeCodeLocalService.shared
  @StateObject private var codexCliService = CodexCliLocalService.shared
  @StateObject private var cursorService = CursorLocalService.shared
  @StateObject private var claudeAccountStore = ClaudeCodeAccountStore.shared
  @StateObject private var providerVisibility = ProviderVisibilityStore.shared
  @StateObject private var sessionWakeStore = SessionWakeSettingsStore.shared

  @State private var contentHeight: CGFloat = 320
  @State private var expandedDetailID: String?
  @State private var cardFrames: [String: CGRect] = [:]
  @State private var menuWindow: NSWindow?

  init(onContentSizeChange: @escaping (NSSize) -> Void = { _ in }) {
    self.onContentSizeChange = onContentSizeChange
  }

  var body: some View {
    mainColumn
    .frame(width: popoverWidth, height: popoverHeight)
    .background(MeterBarCompanionSurface(radius: MeterBarTheme.companionShellRadius))
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
      cardFrames = frames
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
                claudeAccounts: claudeAccountStore.accounts,
                claudeAccountMetrics: dataManager.claudeCodeAccountMetrics,
                enabledServices: providerVisibility.enabledServices,
                claudeCodeHasAccess: claudeCodeService.hasAccess,
                codexCliHasAccess: codexCliService.hasAccess,
                cursorHasAccess: cursorService.hasAccess
              )),
            openDashboard: openDashboard,
            openStatusDetail: openStatusDetail,
            openProviderOverview: openProviderDetail
          )

          if SessionWakeMenuControl.shouldShow(
            isOn: sessionWakeStore.isOn,
            canTurnOn: sessionWakeStore.canTurnOn
          ) {
            Divider()
            SessionWakeMenuControl()
          }
        }
        .padding(10)
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
      Spacer()

      Button(action: openDashboard) {
        Image(systemName: MenuBarOverlayIcons.dashboard)
          .font(.system(size: 12, weight: .semibold))
      }
      .meterBarGlassIconButton()
      .help("Open Usage Dashboard")

      Button {
        Task { await dataManager.refreshAll() }
      } label: {
        RefreshingIcon(isRefreshing: dataManager.isLoading)
          .font(.system(size: 12, weight: .semibold))
      }
      .meterBarGlassIconButton()
      .help(dataManager.isLoading ? "Refreshing usage" : "Refresh usage")
      .disabled(dataManager.isLoading)
    }
    .font(.body)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
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
    guard let menuWindow, let frame = cardFrames[id] else { return nil }
    return menuWindow.frame.maxY - frame.minY
  }

  private func configureMenuWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
  }
}

private extension View {
  func meterBarGlassIconButton() -> some View {
    frame(width: 30, height: 30)
      .contentShape(Circle())
      .glassEffect(.regular, in: Circle())
      .buttonStyle(.plain)
  }
}

private enum MenuBarOverlayIcons {
  static let dashboard = "rectangle.split.2x1"
}

// MARK: - Overview panel

struct PopoverOverviewPanel: View {
  let snapshots: [ProviderSnapshot]
  let openDashboard: () -> Void
  let openStatusDetail: () -> Void
  let openProviderOverview: (ProviderSnapshot) -> Void

  @State private var setupReports: [ProviderReadiness] = []

  /// The enabled providers currently shown in the popover.
  private var enabledProviders: Set<ServiceType> {
    Set(snapshots.map(\.service))
  }

  /// Enabled providers that still need setup — drives the first-run checklist.
  /// The section collapses (renders nothing) once these are all healthy.
  private var providersNeedingSetup: [ProviderReadiness] {
    setupReports.filter { enabledProviders.contains($0.provider) && !$0.isHealthy }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if snapshots.isEmpty {
        DashboardTile(padding: 12) {
          HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.fill")
              .font(.system(size: 17, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: 34, height: 34)

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
        }
      }

      if !providersNeedingSetup.isEmpty {
        setupChecklist
      }

      PopoverProviderStatusSummaryCard(openStatusDetail: openStatusDetail)
        .reportPopoverCardFrame(id: PopoverCardID.providerStatus)

      VStack(spacing: 8) {
        ForEach(snapshots) { snapshot in
          PopoverProviderStatusCard(snapshot: snapshot) {
            openProviderOverview(snapshot)
          }
          .reportPopoverCardFrame(id: snapshot.id)
        }
      }
    }
    .task {
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
      ReadinessChecklist(reports: providersNeedingSetup, compact: true)
    }
  }

  /// Runs the readiness inspector off the main actor (keychain / file / SQLite
  /// I/O) and publishes the reports back for the checklist.
  private func loadSetupReports() async {
    let requestedProviders = enabledProviders
    let reports = await Task.detached(priority: .utility) {
      ProviderReadinessInspector.reports(providers: requestedProviders)
    }.value
    setupReports = reports
  }
}

private struct PopoverProviderStatusCard: View {
  let snapshot: ProviderSnapshot
  var onSelect: (() -> Void)?

  private var statusColor: Color {
    snapshot.band?.color ?? .secondary
  }

  private var statusText: String {
    snapshot.band?.shortLabel ?? "Offline"
  }

  var body: some View {
    Group {
      if let onSelect {
        Button(action: onSelect) {
          cardContent
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open \(snapshot.title) provider details")
      } else {
        cardContent
      }
    }
  }

  private var cardContent: some View {
    Group {
      if snapshot.hasExhaustedLimit {
        compactExhaustedCard
      } else {
        expandedCard
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var compactExhaustedCard: some View {
    DashboardTile(padding: 11, minHeight: 58, alignment: .center) {
      VStack(alignment: .leading, spacing: 8) {
        TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
          let blockingWindow = BlockingLimitResetCounter.selectBlockingWindow(
            snapshot.resetWindows,
            now: timeline.date
          )
          let title = BlockingLimitResetCounter.titleText(for: blockingWindow, in: snapshot.resetWindows)
          let counter = BlockingLimitResetCounter.counterText(for: blockingWindow, now: timeline.date)

          HStack(alignment: .center, spacing: 9) {
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

            Spacer(minLength: 8)

            HStack(spacing: 5) {
              Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .semibold))
              Text("\(title) \(counter)")
                .font(.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .foregroundColor(snapshot.accentColor)
            .help("\(title) \(counter)")
          }
        }

        let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
        if badges.hasContent {
          badges
        }
      }
    }
  }

  private var expandedCard: some View {
    DashboardTile(
      padding: 11,
      minHeight: 124
    ) {
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
        }

        if snapshot.limits.isEmpty {
          Text(snapshot.emptyDetail)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        } else {
          VStack(alignment: .leading, spacing: 9) {
            ForEach(snapshot.limits) { limit in
              PopoverLimitRow(limit: limit, accentColor: snapshot.accentColor)
            }
          }
        }

        let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
        if badges.hasContent {
          badges
        }
      }
    }
  }

  private var updatedText: String {
    guard let updatedAt = snapshot.updatedAt else { return "No data" }
    return "Updated \(UsageFormat.relative(updatedAt))"
  }
}

private struct PopoverLimitRow: View {
  let limit: SnapshotLimit
  let accentColor: Color

  private var isOut: Bool {
    limit.percentLeft <= 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(limit.title)
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(isOut ? "Out" : "\(limit.percentLeft)% left")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
          .lineLimit(1)
      }

      UsageBar(
        usedPercentage: limit.usedPercent,
        accentColor: accentColor,
        pace: limit.usageLimit.pace(),
        paceContext: limit.paceContext
      )

      if limit.usageLimit.resetTime != nil {
        ResetCountdownLabel(
          title: limit.title,
          limit: limit.usageLimit,
          font: .caption2,
          foregroundColor: .secondary,
          iconSize: 9
        )
      }
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
