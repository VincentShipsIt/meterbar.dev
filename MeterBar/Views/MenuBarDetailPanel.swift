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
    )
    panel.applyCompanionClipping()
    panel.setFrame(frame, display: true)
    panel.orderFront(nil)
  }

  func dismiss() {
    panel?.orderOut(nil)
  }

  func owns(window: NSWindow?) -> Bool {
    guard let window, let panel else { return false }
    return window === panel
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

  private var detailLimits: [SnapshotLimit] {
    snapshot.detailLimits
  }

  private var quotaWindowHeading: String {
    detailLimits.count == 1 ? "Quota Window" : "Quota Windows"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.bottom, MeterBarTheme.Spacing.md)

      Divider()

      ViewThatFits(in: .vertical) {
        detailRows

        ScrollView(showsIndicators: false) {
          detailRows
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
      }
    }
    .padding(MeterBarTheme.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MeterBarTheme.Surface.chrome(radius: MeterBarMenuDetailPanelLayout.cornerRadius))
    .clipShape(
      RoundedRectangle(
        cornerRadius: MeterBarMenuDetailPanelLayout.cornerRadius,
        style: .continuous
      )
    )
  }

  private var detailRows: some View {
    VStack(alignment: .leading, spacing: 12) {
      if detailLimits.isEmpty {
        Text(snapshot.emptyDetail)
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, MeterBarTheme.Spacing.md)
      } else {
        if snapshot.hasExhaustedLimit {
          BlockingLimitResetCounter(
            windows: snapshot.resetWindows,
            accentColor: snapshot.accentColor
          )
          .padding(MeterBarTheme.Spacing.md)
          .meterBarCardSurface(cornerRadius: MeterBarTheme.detailCardRadius)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text(quotaWindowHeading)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)

          ForEach(detailLimits) { limit in
            LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .detail)
          }
        }
      }

      let badges = ProviderStatusBadges(snapshot: snapshot, style: .compact)
      if badges.hasContent {
        badges
          .padding(.top, MeterBarTheme.Spacing.xxs)
      }
    }
    .padding(.top, MeterBarTheme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: snapshot.accentColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(snapshot.title)
          .font(.headline)
          .fontWeight(.semibold)
          .lineLimit(1)
        Text(snapshot.service.displayName)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
  }
}

// The detail-panel limit row is now `LimitRow(density: .detail)` — see
// MeterBar/Views/Components/LimitRow.swift. It keeps the per-row card surface
// that this bespoke `MenuBarProviderLimitDetailRow` used to draw inline.
