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
    /// Header + divider above the scroll area.
    static let chromeHeight: CGFloat = 41
    /// Breathing room kept between the popover and each screen edge.
    static let screenPadding: CGFloat = 8
    /// Absolute ceiling, independent of how tall the display is.
    static let maximumHeightCap: CGFloat = 760
    static let minimumScrollHeight: CGFloat = 80
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
