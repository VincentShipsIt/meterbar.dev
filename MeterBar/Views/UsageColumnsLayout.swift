import SwiftUI

/// Sizes for the Usage page's two columns.
enum UsageColumnsMetrics {
    /// The insights column's width when it sits beside the main column.
    static let sideColumnWidth: CGFloat = 300
    /// Narrowest main column worth keeping beside the insights. Below it the
    /// chart's x-axis and the breakdown table's five columns are cramped.
    static let minimumMainWidth: CGFloat = 520
    static let spacing: CGFloat = 14

    /// The width below which the insights column drops under the main column.
    static var collapseWidth: CGFloat { minimumMainWidth + spacing + sideColumnWidth }

    static func isCollapsed(width: CGFloat) -> Bool {
        width < collapseWidth
    }
}

/// Main column plus a fixed-width insights column, collapsing to one column
/// under the main content when the window is too narrow for both.
///
/// A `Layout` rather than `ViewThatFits`: the columns hold live charts and
/// tables, and `ViewThatFits` builds every candidate, which would instantiate
/// each of them twice and lose their `@State` when the window crosses the
/// threshold. It is also decided during layout from the width it is actually
/// given, so there is no measured-width state to lag a frame behind. Each
/// column is one view that is only ever repositioned.
///
/// Expects exactly two subviews: the main column, then the side column. The
/// side column is where the routing UI planned in epic #513 (phase 2) can be
/// added alongside the insights; nothing for it exists yet.
struct UsageColumnsLayout: Layout {
    private struct Frames {
        let main: CGRect
        let side: CGRect
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        return frames(in: proposal.width ?? UsageColumnsMetrics.collapseWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = frames(in: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, [frames.main, frames.side]) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func frames(in width: CGFloat, subviews: Subviews) -> Frames {
        let width = max(0, width)
        let spacing = UsageColumnsMetrics.spacing
        if UsageColumnsMetrics.isCollapsed(width: width) {
            let mainHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let sideHeight = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return Frames(
                main: CGRect(x: 0, y: 0, width: width, height: mainHeight),
                side: CGRect(x: 0, y: mainHeight + spacing, width: width, height: sideHeight),
                size: CGSize(width: width, height: mainHeight + spacing + sideHeight)
            )
        }
        let sideWidth = UsageColumnsMetrics.sideColumnWidth
        let mainWidth = width - sideWidth - spacing
        let mainHeight = subviews[0].sizeThatFits(ProposedViewSize(width: mainWidth, height: nil)).height
        let sideHeight = subviews[1].sizeThatFits(ProposedViewSize(width: sideWidth, height: nil)).height
        return Frames(
            main: CGRect(x: 0, y: 0, width: mainWidth, height: mainHeight),
            side: CGRect(x: mainWidth + spacing, y: 0, width: sideWidth, height: sideHeight),
            size: CGSize(width: width, height: max(mainHeight, sideHeight))
        )
    }
}
