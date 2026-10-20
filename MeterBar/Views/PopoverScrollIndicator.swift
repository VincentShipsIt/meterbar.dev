import AppKit
import SwiftUI

/// Where a scroll view sits, in the units the thumb needs.
struct PopoverScrollMetrics: Equatable {
  var offset: CGFloat = 0
  var content: CGFloat = 0
  var viewport: CGFloat = 0

  var isScrollable: Bool { content - viewport > 1 }

  /// Thumb length and top offset inside a track of `viewport` points.
  func thumb(minimumLength: CGFloat) -> (length: CGFloat, top: CGFloat) {
    guard isScrollable, content > 0 else { return (0, 0) }
    let length = min(viewport, max(minimumLength, viewport * viewport / content))
    let progress = min(max(offset / (content - viewport), 0), 1)
    return (length, progress * (viewport - length))
  }
}

/// The thumb's live state, kept out of `MenuBarView`.
///
/// Scroll geometry changes on every frame of a scroll. Held as `@State` on the
/// popover it re-ran the whole popover body (every provider snapshot rebuilt,
/// every card diffed) per frame. Observable, it is written by the popover but
/// only read by the thumb, so only the thumb redraws.
@MainActor
@Observable
final class PopoverScrollModel {
  var metrics = PopoverScrollMetrics()
  var isActive = false
  @ObservationIgnored private var idleTask: Task<Void, Never>?

  func update(from oldValue: PopoverScrollMetrics, to newValue: PopoverScrollMetrics) {
    metrics = newValue
    guard abs(oldValue.offset - newValue.offset) > 0.5 else { return }
    if !isActive { isActive = true }
    idleTask?.cancel()
    idleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      self?.isActive = false
    }
  }
}

/// Reads `PopoverScrollModel` so its per-frame changes redraw only the thumb.
struct PopoverScrollThumb: View {
  let model: PopoverScrollModel
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    PopoverScrollIndicator(metrics: model.metrics, isActive: model.isActive)
      .animation(
        MeterBarTheme.Motion.resolve(.smooth(duration: 0.25), reduceMotion: reduceMotion),
        value: model.isActive
      )
  }
}

/// A slim, free-floating thumb in the gutter beside the cards.
///
/// The popover has no shell to hang a scroller on, so the system's legacy bar
/// (a grey track with a fat knob) reads as a stray object. This draws only the
/// thumb: it appears while the content moves, and fades away after.
struct PopoverScrollIndicator: View {
  let metrics: PopoverScrollMetrics
  let isActive: Bool

  static let width: CGFloat = 3
  static let minimumLength: CGFloat = 28

  var body: some View {
    let thumb = metrics.thumb(minimumLength: Self.minimumLength)
    Capsule()
      .fill(.primary.opacity(0.42))
      .frame(width: Self.width, height: thumb.length)
      .offset(y: thumb.top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .opacity(metrics.isScrollable && isActive ? 1 : 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Switches off the enclosing `NSScrollView`'s own scroller.
///
/// SwiftUI's `.scrollIndicators(.hidden)` is not honoured when the system is set
/// to always show scroll bars, so the legacy track kept appearing. Placed inside
/// the scroll content, this reaches the AppKit scroll view and removes it.
struct PopoverNativeScrollerHider: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { Self.hide(from: view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { Self.hide(from: nsView) }
  }

  private static func hide(from view: NSView) {
    guard let scrollView = view.enclosingScrollView else { return }
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
  }
}
