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
    /// Space between the hover column and the popover, bridged by a glass neck.
    static let detailGap: CGFloat = 6
    /// The glass neck joining the hover column to the card that opened it: it
    /// overlaps the column by `bridgeWidth - detailGap` and touches the card.
    static let bridgeWidth: CGFloat = 26
    static let bridgeHeight: CGFloat = 36
    /// How far the window grows to the left while a hover is open.
    static let detailExtension: CGFloat = detailWidth + detailGap
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
