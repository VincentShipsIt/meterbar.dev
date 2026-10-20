import AppKit
import MeterBarShared
import SwiftUI

struct MeterBarMenuWindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onResolve(view.window) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { onResolve(nsView.window) }
  }
}

@MainActor
final class MeterBarMenuDetailPanel {
  static let shared = MeterBarMenuDetailPanel()

  private var panel: NSPanel?

  /// Bumped on every `present()`/`dismiss()`. A deferred fade-out completion
  /// only orders the panel out if the token still matches, so re-presenting the
  /// card (e.g. hovering to another row) cancels the pending hide.
  private var presentationToken = 0

  /// Whether present/dismiss animate. Honors Reduce Motion; overridable in tests.
  var motionEnabled = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  /// Hover ownership spans two separate windows with a 12pt gap between them.
  /// A short deferred close lets the pointer cross that gap without flashing
  /// the detail panel closed, while still dismissing as soon as it owns neither
  /// the source card nor the detail surface.
  private var sourceIsHovered = false
  private var detailIsHovered = false
  private var hoverDismissTask: Task<Void, Never>?
  private var hoverDismissAction: (() -> Void)?

  /// Presents the detail card next to `anchor`. `preferredTopY` (screen
  /// coordinates) top-aligns the card with the row that opened it; without it
  /// the card aligns with the anchor's top edge.
  func present(anchor: NSWindow, content: AnyView, preferredTopY: CGFloat? = nil) {
    let width = MeterBarMenuDetailPanelLayout.detailWidth
    let panel = ensurePanel()
    panel.level = anchor.level
    let measuringView = NSHostingView(
      rootView: content
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    )

    let anchorFrame = anchor.frame
    let visibleFrame = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame
    let frame = MeterBarMenuDetailPanelLayout.panelFrame(
      anchorFrame: anchorFrame,
      visibleFrame: visibleFrame,
      measuredHeight: measuringView.fittingSize.height,
      preferredTopY: preferredTopY
    )

    panel.contentView = NSHostingView(
      rootView: content
        .frame(width: frame.width, height: frame.height)
        .onHover { [weak self] isHovered in
          self?.setDetailHovered(isHovered)
        }
    )
    // No shell clipping: the hover is a stack of free-standing glass cards, and a
    // 24pt mask on the window would shave the outer cards' corners.

    let wasVisible = panel.isVisible
    // Cancel any pending fade-out so re-presenting doesn't get ordered out.
    presentationToken &+= 1

    guard motionEnabled else {
      panel.alphaValue = 1
      panel.setFrame(frame, display: true)
      panel.orderFront(nil)
      return
    }

    if wasVisible {
      // Already on screen (moving between rows): glide the frame and make sure
      // the alpha is restored in case a fade-out was mid-flight.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = MeterBarTheme.Motion.panelResize
        panel.animator().setFrame(frame, display: true)
        panel.animator().alphaValue = 1
      }
    } else {
      panel.alphaValue = 0
      panel.setFrame(frame, display: true)
      panel.orderFront(nil)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = MeterBarTheme.Motion.panelFadeIn
        panel.animator().alphaValue = 1
      }
    }
  }

  func dismiss() {
    guard let panel, panel.isVisible else { return }
    resetHoverOwnership()
    presentationToken &+= 1
    let token = presentationToken

    guard motionEnabled else {
      panel.orderOut(nil)
      panel.alphaValue = 1
      return
    }

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = MeterBarTheme.Motion.panelFadeOut
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        // Skip if a newer present/dismiss superseded this fade-out.
        guard let self, self.presentationToken == token else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
      }
    })
  }

  func owns(window: NSWindow?) -> Bool {
    guard let window, let panel else { return false }
    return window === panel
  }

  /// Updates hover ownership for the popover card that opened the detail. The
  /// dismissal callback clears the SwiftUI selection only when the deferred
  /// close actually wins; entering the detail panel cancels it.
  func setSourceHovered(_ isHovered: Bool, onDismiss: @escaping () -> Void) {
    sourceIsHovered = isHovered
    hoverDismissAction = onDismiss
    reconcileHoverDismissal()
  }

  private func setDetailHovered(_ isHovered: Bool) {
    detailIsHovered = isHovered
    reconcileHoverDismissal()
  }

  private func reconcileHoverDismissal() {
    hoverDismissTask?.cancel()
    hoverDismissTask = nil

    guard MeterBarMenuDetailHoverPolicy.shouldDismiss(
      sourceIsHovered: sourceIsHovered,
      detailIsHovered: detailIsHovered
    ), panel?.isVisible == true else { return }

    hoverDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 140_000_000)
      guard let self, !Task.isCancelled, !self.sourceIsHovered, !self.detailIsHovered else { return }
      let onDismiss = self.hoverDismissAction
      self.dismiss()
      onDismiss?()
    }
  }

  private func resetHoverOwnership() {
    hoverDismissTask?.cancel()
    hoverDismissTask = nil
    sourceIsHovered = false
    detailIsHovered = false
    hoverDismissAction = nil
  }

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    let panel = KeyableMenuPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    self.panel = panel
    return panel
  }
}

enum MeterBarMenuDetailHoverPolicy {
  static func shouldDismiss(sourceIsHovered: Bool, detailIsHovered: Bool) -> Bool {
    !sourceIsHovered && !detailIsHovered
  }
}

enum MeterBarMenuDetailPanelLayout {
  static let detailWidth: CGFloat = 340
  static let cornerRadius = MeterBarTheme.companionShellRadius
  static let minDetailHeight: CGFloat = 120
  /// Gap of the standalone panel frame; the live hover now shares the popover
  /// window and uses `MenuBarPopoverGeometry.detailGap`.
  static let panelGap: CGFloat = 8
  static let screenPadding: CGFloat = 8

  /// Screen frame for the detail card: left of the anchor with a gap,
  /// top-aligned with `preferredTopY` (or the anchor's top), clamped to the
  /// visible frame. All rects use AppKit screen coordinates.
  static func panelFrame(
    anchorFrame: CGRect,
    visibleFrame: CGRect,
    measuredHeight: CGFloat,
    preferredTopY: CGFloat? = nil
  ) -> CGRect {
    let maxHeight = max(minDetailHeight, visibleFrame.height - (screenPadding * 2))
    let height = min(max(measuredHeight, minDetailHeight), maxHeight)
    let desiredTop = preferredTopY ?? anchorFrame.maxY
    let topY = min(desiredTop, visibleFrame.maxY - screenPadding)
    let y = max(visibleFrame.minY + screenPadding, topY - height)
    return CGRect(
      x: anchorFrame.minX - detailWidth - panelGap,
      y: y,
      width: detailWidth,
      height: height
    )
  }
}

struct MenuBarProviderDetailContent: View {
  let snapshot: ProviderSnapshot

  /// The hovered provider's trailing week, passed in already bucketed.
  ///
  /// A plain value rather than a `CostTracker` lookup, matching
  /// ``TokenActivityCard``: this panel is hosted directly in
  /// `MenuBarDetailPanelLayoutTests`, and reaching for the scanner singleton
  /// would drag it into every one of those tests. `nil` means the caller has no
  /// series to offer, and the panel simply omits the strip — which is what the
  /// layout tests exercise.
  let dailyUsage: ProviderDailyUsageSeries?
  let isRefreshingUsage: Bool
  /// `CostTracker.lastScanDate` — the cost-scan pipeline's own freshness,
  /// independent of the quota poll `snapshot.updatedAt` reflects. `nil` means
  /// no cost scan has ever run. See `CostScanFreshnessNote` (#530).
  let costScanDate: Date?
  /// False plays the cards' exit. The hosting column clears the content once it
  /// has finished.
  let isPresented: Bool

  @ObservedObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared

  init(
    snapshot: ProviderSnapshot,
    dailyUsage: ProviderDailyUsageSeries? = nil,
    isRefreshingUsage: Bool = false,
    costScanDate: Date? = nil,
    isPresented: Bool = true
  ) {
    self.snapshot = snapshot
    self.dailyUsage = dailyUsage
    self.isRefreshingUsage = isRefreshingUsage
    self.costScanDate = costScanDate
    self.isPresented = isPresented
  }

  /// Distinguishes the sparkline's cost-scan freshness from the header's
  /// quota-poll freshness. Exposed (not private) so it can be asserted
  /// directly against the wiring, matching `headerContent`.
  var costScanFreshnessNote: CostScanFreshnessNote {
    CostScanFreshnessNote(quotaPollUpdatedAt: snapshot.updatedAt, costScanDate: costScanDate)
  }

  private var detailLimits: [SnapshotLimit] {
    snapshot.detailLimits
  }

  /// One line of the hover panel: a Session or Weekly window drawn as its bar
  /// with the annotated runway chart under it, or any other limit as the plain
  /// detail bar.
  enum DetailRow {
    case runway(SnapshotLimit)
    case bar(SnapshotLimit)

    var limit: SnapshotLimit {
      switch self {
      case .runway(let limit), .bar(let limit): limit
      }
    }

    var isRunway: Bool {
      if case .runway = self { true } else { false }
    }
  }

  /// The popover keeps bars; the hover is where the charts live. Every limit
  /// that can be projected becomes a runway, in the card's own order, and the
  /// rest (estimated, no window, credits, model and review windows) stay bars.
  static func rows(for limits: [SnapshotLimit], now: Date = Date()) -> [DetailRow] {
    limits.map { RunwayContent.isEligible($0, now: now) ? .runway($0) : .bar($0) }
  }

  /// The three-line key is shown once, and only when a chart is on screen.
  static func showsRunwayLegend(for rows: [DetailRow]) -> Bool {
    rows.contains { $0.isRunway }
  }

  /// The identity row this panel shows, exposed so it can be asserted equal to
  /// the card's.
  var headerContent: ProviderCardHeader.Content {
    ProviderCardHeader.Content(snapshot: snapshot)
  }

  /// One free-standing card of the hover, in reading order.
  ///
  /// The hover used to be a single glass shell with the header, every window and
  /// the weekly strip drawn flat inside it. Each block is now its own card so
  /// the sections separate cleanly and no card nests inside another surface.
  enum DetailCard: Equatable {
    case header
    /// A limit window. `showsLegend` is true on exactly one runway card, the
    /// last, so the three-line key appears once under the final chart.
    case limit(id: String, isRunway: Bool, showsLegend: Bool)
    case blockingReset
    case empty
    case badges
    case dailyUsage
  }

  /// The ordered cards for a snapshot. Pure so the layout rules are asserted
  /// without hosting a view.
  static func cards(
    limits: [SnapshotLimit],
    hasExhaustedLimit: Bool,
    hasBadges: Bool,
    showsDailyUsage: Bool,
    now: Date = Date()
  ) -> [DetailCard] {
    var cards: [DetailCard] = [.header]
    if limits.isEmpty {
      cards.append(.empty)
    } else if hasExhaustedLimit {
      cards.append(.blockingReset)
    } else {
      let rows = Self.rows(for: limits, now: now)
      let lastRunwayID = rows.last(where: { $0.isRunway })?.limit.id
      cards += rows.map { row in
        .limit(id: row.limit.id, isRunway: row.isRunway, showsLegend: row.limit.id == lastRunwayID)
      }
    }
    if hasBadges { cards.append(.badges) }
    if showsDailyUsage { cards.append(.dailyUsage) }
    return cards
  }

  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var badges: ProviderStatusBadges {
    ProviderStatusBadges(snapshot: snapshot, style: .compact)
  }

  private var showsDailyUsage: Bool {
    dailyUsage?.showsInOverview ?? false
  }

  private var orderedCards: [DetailCard] {
    Self.cards(
      limits: detailLimits,
      hasExhaustedLimit: snapshot.hasExhaustedLimit,
      hasBadges: badges.hasContent,
      showsDailyUsage: showsDailyUsage
    )
  }

  var body: some View {
    // This column shares the popover window's glass container, so its cards
    // blend with the popover cards as they slide in and settle apart once the
    // gaps open, which is what makes the stack read as budding out of the card
    // that opened it. A standalone hosting (tests) has no container and simply
    // draws separate glass cards.
    ViewThatFits(in: .vertical) {
      cardStack

      ScrollView(showsIndicators: false) {
        cardStack
      }
      .scrollIndicators(.hidden)
      .scrollContentBackground(.hidden)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .onAppear { appeared = true }
  }

  private var cardStack: some View {
    let cards = orderedCards
    return VStack(alignment: .leading, spacing: MeterBarTheme.Spacing.md) {
      ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
        HoverCardSurface(index: index, revealed: appeared && isPresented, reduceMotion: reduceMotion) {
          content(for: card)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func content(for card: DetailCard) -> some View {
    switch card {
    case .header:
      ProviderCardHeader(snapshot: snapshot)
    case .limit(let id, let isRunway, let showsLegend):
      if let limit = detailLimits.first(where: { $0.id == id }) {
        VStack(alignment: .leading, spacing: 10) {
          LimitRow(
            limit: limit,
            accentColor: snapshot.accentColor,
            density: .detail,
            resetTimeFormat: menuBarDisplayPreferences.resetTimeFormat
          )
          if isRunway {
            RunwayView(limit: limit, accentColor: snapshot.accentColor, showsFooter: false)
          }
          if showsLegend {
            RunwayLegend(accentColor: snapshot.accentColor)
          }
        }
      }
    case .blockingReset:
      BlockingLimitResetCounter(
        windows: snapshot.resetWindows,
        accentColor: snapshot.accentColor,
        format: menuBarDisplayPreferences.resetTimeFormat
      )
    case .empty:
      Text(snapshot.emptyDetail)
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .badges:
      badges
    case .dailyUsage:
      if let dailyUsage {
        // The week behind the windows above: reading top to bottom is now, then
        // the recent past.
        ProviderDailyUsageSparkline(
          series: dailyUsage,
          accentColor: snapshot.accentColor,
          isRefreshing: isRefreshingUsage,
          scanFreshness: costScanFreshnessNote
        )
      }
    }
  }
}

/// A free-standing glass card of the hover. Its entrance, a short stagger of
/// slide, scale and fade from the trailing edge (the side the popover is on),
/// is driven by `revealed` and drops to an instant update under Reduce Motion.
private struct HoverCardSurface<Content: View>: View {
  let index: Int
  let revealed: Bool
  let reduceMotion: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(MeterBarTheme.CardPadding.popover.value)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .meterBarGlassCard()
      .scaleEffect(revealed ? 1 : 0.72, anchor: .trailing)
      .offset(x: revealed ? 0 : 36)
      .opacity(revealed ? 1 : 0)
      .animation(
        MeterBarTheme.Motion.resolve(
          .smooth(duration: 0.24).delay(Double(index) * 0.03),
          reduceMotion: reduceMotion
        ),
        value: revealed
      )
  }
}

// The detail-panel limit row is now `LimitRow(density: .detail)` — see
// MeterBar/Views/Components/LimitRow.swift, which selects the fuller footer
// without changing the row's chrome.
