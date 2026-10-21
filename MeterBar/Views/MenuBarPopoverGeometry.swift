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
    /// A 30pt control row with 6pt breathing room below.
    static let chromeHeight: CGFloat = 36
    /// Breathing room kept between the popover and each screen edge.
    static let screenPadding: CGFloat = 8
    /// Absolute ceiling, independent of how tall the display is.
    static let maximumHeightCap: CGFloat = 760
    static let minimumScrollHeight: CGFloat = 80
    /// Width of the hover column that opens to the left of the popover.
    static let detailWidth: CGFloat = 340
    /// Inset of the popover cards from the popover's own edges (`Spacing.md`).
    static let cardInset: CGFloat = 12
    /// Space between neighbouring cards, in the popover and the hover alike.
    static let cardGap: CGFloat = 6
    /// Visible space between the hover column and the popover cards.
    static let detailGap: CGFloat = cardGap
    /// How far the window grows to the left while a hover is open. The column
    /// tucks into the popover's own card inset so the visible gap is `detailGap`.
    static let detailExtension: CGFloat = detailWidth + detailGap - cardInset
    /// Leading edge of the popover cards, in window coordinates, while a hover
    /// is open.
    static let popoverCardMinX: CGFloat = detailExtension + cardInset
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

    /// Reserve one transparent hover canvas while details are open. Switching
    /// between short errors and tall charts never resizes the native window.
    static func windowSize(
        popover: NSSize,
        hasDetail: Bool,
        maximumHeight: CGFloat
    ) -> NSSize {
        guard hasDetail else { return popover }
        return NSSize(
            width: popover.width + detailExtension,
            height: maximumHeight
        )
    }

    /// Top of the hover column, from the window top: level with the card that
    /// opened it, raised just enough to keep a tall column on screen, never
    /// above the window top.
    static func detailTop(sourceTop: CGFloat, detailHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        max(0, min(sourceTop, maximumHeight - detailHeight))
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

/// Source ownership survives out-of-order exit events while switching cards.
struct PopoverHoverOwnership {
    var isOverPopover = false
    var sourceID: String?
    var hoveredDetailID: String?

    mutating func updateSource(id: String, isHovered: Bool) {
        if isHovered {
            sourceID = id
        } else if sourceID == id {
            sourceID = nil
        }
    }

    mutating func updateDetail(id: String, isHovered: Bool) {
        if isHovered {
            hoveredDetailID = id
        } else if hoveredDetailID == id {
            hoveredDetailID = nil
        }
    }

    func shouldDismiss(detailID: String) -> Bool {
        if let sourceID { return sourceID != detailID }
        return !isOverPopover && hoveredDetailID != detailID
    }
}
