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
    panel.applyCompanionClipping()

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
  static let panelGap: CGFloat = 12
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

  @ObservedObject private var menuBarDisplayPreferences = MenuBarDisplayPreferencesStore.shared

  init(
    snapshot: ProviderSnapshot,
    dailyUsage: ProviderDailyUsageSeries? = nil,
    isRefreshingUsage: Bool = false
  ) {
    self.snapshot = snapshot
    self.dailyUsage = dailyUsage
    self.isRefreshingUsage = isRefreshingUsage
  }

  private var detailLimits: [SnapshotLimit] {
    snapshot.detailLimits
  }

  /// The identity row this panel shows, exposed so it can be asserted equal to
  /// the card's.
  var headerContent: ProviderCardHeader.Content {
    ProviderCardHeader.Content(snapshot: snapshot)
  }

  var body: some View {
    // Spacing, not a divider: the panel is the same card the pointer is resting
    // on, only wider, so it must not sprout chrome the card never had.
    VStack(alignment: .leading, spacing: 10) {
      ProviderCardHeader(snapshot: snapshot)

      ViewThatFits(in: .vertical) {
        detailRows

        ScrollView(showsIndicators: false) {
          detailRows
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
      }
    }
    // The same inset as the card this panel expands, so the header and rows sit
    // at the same distance from the edge in both — a wider card, not a new one.
    .padding(MeterBarTheme.CardPadding.popover.value)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MeterBarTheme.Surface.chrome(radius: MeterBarMenuDetailPanelLayout.cornerRadius))
    .clipShape(
      RoundedRectangle(
        cornerRadius: MeterBarMenuDetailPanelLayout.cornerRadius,
        style: .continuous
      )
    )
  }

  // Same order and same spacings as `ProviderStatusCard.expandedCardBody`: the
  // reset counter and the limit rows are drawn flat inside this one surface, not
  // wrapped in cards of their own. The only thing the extra width buys is the
  // fuller `.detail` row footer.
  private var detailRows: some View {
    VStack(alignment: .leading, spacing: 10) {
      if detailLimits.isEmpty {
        Text(snapshot.emptyDetail)
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, MeterBarTheme.Spacing.md)
      } else if snapshot.hasExhaustedLimit {
        BlockingLimitResetCounter(
          windows: snapshot.resetWindows,
          accentColor: snapshot.accentColor,
          format: menuBarDisplayPreferences.resetTimeFormat
        )
      } else {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(detailLimits) { limit in
            LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .detail)
          }
        }
      }

      let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
      if badges.hasContent {
        badges
      }

      if let dailyUsage {
        // Last, and separated by a little extra space rather than a rule: the
        // rows above are the window the card already summarised, and this is the
        // week behind it. Reading top-to-bottom is now → recent past.
        ProviderDailyUsageSparkline(
          series: dailyUsage,
          accentColor: snapshot.accentColor,
          isRefreshing: isRefreshingUsage
        )
          .padding(.top, MeterBarTheme.Spacing.xxs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

// The detail-panel limit row is now `LimitRow(density: .detail)` — see
// MeterBar/Views/Components/LimitRow.swift, which selects the fuller footer
// without changing the row's chrome.
