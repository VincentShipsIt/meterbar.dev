import SwiftUI

// MARK: - ProviderMasonryLayout

/// Round-robin masonry that keeps every card a sibling in one container.
///
/// The dashboard used to build this by partitioning the snapshots into per-column
/// arrays and nesting a `ForEach` inside a `ForEach` over the columns. That made
/// a card's SwiftUI identity depend on which column it happened to land in, and
/// columns are dealt by array position: when the snapshot list changed — another
/// account finishing a background poll, a provider gaining or losing metrics —
/// every card after the change flipped column, took a different identity path,
/// and had its `@State` discarded. For the Codex reset-credit button that meant
/// a spent credit could be silently re-offered.
///
/// Placing the cards geometrically fixes the identity, not the arrangement: the
/// caller keeps one `ForEach` keyed by snapshot id and the layout decides where
/// each card goes, so a card keeps its state wherever it is placed. The deal is
/// unchanged — same round robin, same reading order, same balance — so the grid
/// looks exactly as it did.
struct ProviderMasonryLayout: Layout {
    // MARK: Internal

    var columnCount: Int
    var spacing: CGFloat

    /// Deals items round-robin across `columnCount` independent columns.
    ///
    /// `LazyVGrid` locks every card in a row to the tallest card in that row, so
    /// a provider with two quota windows left a block of dead space beside a
    /// provider with four. Columns that flow on their own pack tight instead.
    /// Round-robin keeps reading order running left-to-right across each row
    /// and keeps the columns balanced to within one card.
    ///
    /// Kept as a standalone function (rather than folded into `frames`) so the
    /// ordering and balance can be unit-tested on their own.
    nonisolated static func columns<Element>(_ items: [Element], columnCount: Int) -> [[Element]] {
        let count = max(1, columnCount)
        var columns = [[Element]](repeating: [], count: count)
        for (index, item) in items.enumerated() {
            columns[index % count].append(item)
        }
        return columns
    }

    /// Frames for cards of `heights`, relative to the layout's origin.
    ///
    /// Pure so the deal, the column widths, and the independent stacking can be
    /// asserted without hosting a view.
    nonisolated static func frames(
        heights: [CGFloat],
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat
    ) -> [CGRect] {
        let count = max(1, columnCount)
        let width = columnWidth(containerWidth: containerWidth, columnCount: count, spacing: spacing)
        var nextY = [CGFloat](repeating: 0, count: count)
        var frames = [CGRect](repeating: .zero, count: heights.count)

        for (index, column) in columns(Array(heights.indices), columnCount: count).enumerated() {
            let x = (width + spacing) * CGFloat(index)
            for item in column {
                frames[item] = CGRect(x: x, y: nextY[index], width: width, height: heights[item])
                nextY[index] += heights[item] + spacing
            }
        }
        return frames
    }

    /// Height of the tallest column, so a short column never pads the section
    /// out to a ragged bottom edge.
    nonisolated static func totalHeight(of frames: [CGRect]) -> CGFloat {
        frames.map(\.maxY).max() ?? 0
    }

    /// Width one card occupies: the container minus the gutters between columns.
    nonisolated static func columnWidth(
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        let count = max(1, columnCount)
        let gutters = spacing * CGFloat(count - 1)
        return max(0, (containerWidth - gutters) / CGFloat(count))
    }

    nonisolated func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = resolvedWidth(for: proposal)
        let frames = Self.frames(
            heights: heights(of: subviews, containerWidth: width),
            containerWidth: width,
            columnCount: columnCount,
            spacing: spacing
        )
        return CGSize(width: width, height: Self.totalHeight(of: frames))
    }

    nonisolated func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let frames = Self.frames(
            heights: heights(of: subviews, containerWidth: bounds.width),
            containerWidth: bounds.width,
            columnCount: columnCount,
            spacing: spacing
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    // MARK: Private

    /// Cards are sized at their column's width before being stacked, so a tall
    /// wrapping card reports the height it will actually occupy.
    nonisolated private func heights(of subviews: Subviews, containerWidth: CGFloat) -> [CGFloat] {
        let width = Self.columnWidth(
            containerWidth: containerWidth,
            columnCount: columnCount,
            spacing: spacing
        )
        return subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    /// The section always fills the page width; an unspecified proposal only
    /// happens in sizing passes, where the ideal width is the best answer.
    nonisolated private func resolvedWidth(for proposal: ProposedViewSize) -> CGFloat {
        proposal.width ?? proposal.replacingUnspecifiedDimensions().width
    }
}
