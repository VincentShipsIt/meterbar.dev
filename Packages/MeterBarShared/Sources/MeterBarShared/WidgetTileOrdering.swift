import Foundation

/// How the Tiles widget deals its rows: the tightest measured quota first,
/// so the small size's single tile is always the one to watch.
public enum WidgetTileOrdering {
    /// Rows sorted by headroom, least first. A blocked row leads; a row with
    /// no measured percentage (credits, unavailable) goes last. Ties keep the
    /// planner's order.
    public static func tightestFirst(_ rows: [WidgetPresentationRow]) -> [WidgetPresentationRow] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element)
                let right = rank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Sort key: blocked rows at -1, measured rows by percent left, the rest
    /// after every measured row.
    static func rank(_ row: WidgetPresentationRow) -> Int {
        if row.isBlocked { return -1 }
        guard let limit = row.limit, limit.reading == .measured else { return 1_000 }
        return QuotaMath.percentLeft(for: limit)
    }
}
