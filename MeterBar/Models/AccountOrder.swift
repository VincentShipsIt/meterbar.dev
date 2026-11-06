import Foundation

/// The drag-to-reorder rule every multi-account store shares.
///
/// `offsets` and `destination` follow SwiftUI's `onMove`: `destination` is an
/// index into the list *before* the moved rows are taken out. One rule for all
/// four providers keeps their Settings lists from reordering differently.
nonisolated enum AccountOrder {
    /// `ids` with the rows at `offsets` moved to `destination`, or `nil` when
    /// there is nothing to order or an offset is out of range, so the caller
    /// keeps its stored order untouched.
    static func moving<ID>(_ ids: [ID], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [ID]? {
        guard !ids.isEmpty else { return nil }
        let movingIndexes = offsets.sorted()
        guard movingIndexes.allSatisfy({ ids.indices.contains($0) }) else { return nil }

        var ordered = ids
        let moving = movingIndexes.map { ordered[$0] }
        for index in movingIndexes.reversed() {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = movingIndexes.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removedBeforeDestination, ordered.count))
        ordered.insert(contentsOf: moving, at: adjustedDestination)
        return ordered
    }
}
