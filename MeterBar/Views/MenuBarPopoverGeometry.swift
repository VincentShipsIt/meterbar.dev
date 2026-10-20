import AppKit
import Foundation

/// Popover sizing rules extracted from `MenuBarView` (C1 split).
///
/// The view previously carried four private constants and three private
/// computed properties, and `notifyContentSize` re-derived the same clamp chain
/// by hand — so the height the popover *rendered* at and the height it
/// *reported* to the menu-bar window controller were two independent copies of
/// one rule. Hoisting the math into statics makes the window/content agreement
/// assertable without hosting a view.
enum MenuBarPopoverGeometry {
    static let width: CGFloat = 390
    static let minimumHeight: CGFloat = 180
    /// The header bar that floats over the top of the scroll area: a 30pt glass
    /// capsule plus `Spacing.sm` above and below.
    static let chromeHeight: CGFloat = 46
    /// Breathing room kept between the popover and each screen edge.
    static let screenPadding: CGFloat = 8
    /// Absolute ceiling, independent of how tall the display is.
    static let maximumHeightCap: CGFloat = 760
    static let minimumScrollHeight: CGFloat = 80
    /// Width of the hover column that opens to the left of the popover.
    static let detailWidth: CGFloat = 340
    /// Inset of the popover cards from the popover's own edges (`Spacing.md`).
    static let cardInset: CGFloat = 12
    /// Visible space between the hover column and the popover card that opened
    /// it, bridged by a glass neck.
    static let detailGap: CGFloat = 6
    /// Glass shapes in the hover's container closer than this melt into one.
    /// Below every resting gap, so cards only fuse where they touch: the bridge
    /// with both ends, and the hover cards with the source card on the way in.
    static let blendDistance: CGFloat = 4
    /// The glass neck reaches this far into the hover column and into the card.
    static let bridgeOverlap: CGFloat = 10
    static let bridgeHeight: CGFloat = 36
    /// Where the bridge sits below the column top: level with the header card.
    static let bridgeTopOffset: CGFloat = 8
    /// How far the window grows to the left while a hover is open. The column
    /// tucks into the popover's own card inset so the visible gap is `detailGap`.
    static let detailExtension: CGFloat = detailWidth + detailGap - cardInset
    /// Leading edge of the popover cards, in window coordinates, while a hover
    /// is open.
    static let liftedCardMinX: CGFloat = detailExtension + cardInset
    /// Used when neither the popover's own screen nor the main screen is known.
    static let fallbackVisibleScreenHeight: CGFloat = 720

    static func maximumHeight(visibleScreenHeight: CGFloat) -> CGFloat {
        max(minimumHeight, min(maximumHeightCap, visibleScreenHeight - (screenPadding * 2)))
    }

    static func scrollHeight(contentHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        min(max(minimumScrollHeight, contentHeight), maximumHeight - chromeHeight)
    }

    static func popoverHeight(scrollHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        min(max(chromeHeight + scrollHeight, minimumHeight), maximumHeight)
    }

    /// The whole window while a hover may be open: the popover pinned to the
    /// trailing edge, `detailExtension` more width on the left when a hover is
    /// open, and tall enough for whichever column ends lower. `detailBottom` is
    /// the hover's bottom edge measured from the window top.
    static func windowSize(
        popover: NSSize,
        hasDetail: Bool,
        detailBottom: CGFloat,
        maximumHeight: CGFloat
    ) -> NSSize {
        guard hasDetail else { return popover }
        return NSSize(
            width: popover.width + detailExtension,
            height: min(max(popover.height, detailBottom), maximumHeight)
        )
    }

    /// The glass neck from the hover column to the card that opened it, in
    /// window coordinates. It overlaps both by `bridgeOverlap` and sits level
    /// with the hover's header card, `columnTop` being the column's top edge.
    static func bridgeFrame(columnTop: CGFloat) -> CGRect {
        let minX = detailWidth - bridgeOverlap
        let maxX = liftedCardMinX + bridgeOverlap
        return CGRect(x: minX, y: columnTop + bridgeTopOffset, width: maxX - minX, height: bridgeHeight)
    }

    /// The part of the source card's glass the hover draws, in window
    /// coordinates: the card's vertical extent clipped to the scroll viewport,
    /// so a card scrolled under the header bar is not drawn over it. `nil` once
    /// the card has scrolled out of sight.
    static func liftedCardFrame(
        sourceMinY: CGFloat,
        sourceHeight: CGFloat,
        popoverHeight: CGFloat
    ) -> CGRect? {
        let top = max(sourceMinY, chromeHeight)
        let bottom = min(sourceMinY + sourceHeight, popoverHeight)
        guard bottom - top >= 1 else { return nil }
        return CGRect(x: liftedCardMinX, y: top, width: width - cardInset * 2, height: bottom - top)
    }

    /// The size handed to the menu-bar window controller. Derived from the same
    /// two functions the view renders with, so the window can never disagree
    /// with its content.
    static func contentSize(contentHeight: CGFloat, maximumHeight: CGFloat) -> NSSize {
        let scroll = scrollHeight(contentHeight: contentHeight, maximumHeight: maximumHeight)
        return NSSize(
            width: width,
            height: popoverHeight(scrollHeight: scroll, maximumHeight: maximumHeight)
        )
    }
}
