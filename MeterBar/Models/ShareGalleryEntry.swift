import Foundation
import SwiftUI

// MARK: - ShareGalleryEntry

/// One tile in the Share gallery.
///
/// The page used to show a single limits card behind a provider picker, so
/// seeing four accounts meant four round trips through a menu and posting them
/// meant four. The gallery lays every card out at once, which turns the picker
/// into a layout problem: what the page needs is an ordered list of tiles, and
/// which snapshot each one speaks for.
///
/// The receipt leads because it is the only card that summarizes every provider
/// at once; the per-provider cards then follow in the order the rest of the
/// dashboard already lists them, so the gallery and the Limits page agree.
enum ShareGalleryEntry: Identifiable {
    /// The 30-day token receipt — one card for the whole machine.
    case receipt
    /// One provider's live quota windows.
    case limits(ProviderSnapshot)
    /// Stands in for the per-provider cards when nothing is being tracked yet,
    /// so a new user still sees what a limits card looks like instead of a
    /// gallery that silently has one tile in it.
    case limitsPlaceholder

    // MARK: Internal

    var id: String {
        switch self {
        case .receipt: return "share.receipt"
        case let .limits(snapshot): return "share.limits.\(snapshot.id)"
        case .limitsPlaceholder: return "share.limits.placeholder"
        }
    }

    /// The tile's own heading — not the card's, which carries the MeterBar
    /// wordmark. Naming the provider here is what makes a wall of near-identical
    /// dark cards scannable.
    var title: String {
        switch self {
        case .receipt: return "Token Receipt"
        case let .limits(snapshot): return snapshot.title
        case .limitsPlaceholder: return "Limits"
        }
    }

    var subtitle: String {
        switch self {
        case .receipt: return "Last 30 days"
        case let .limits(snapshot): return snapshot.updatedText
        case .limitsPlaceholder: return "No data"
        }
    }

    /// Only the receipt has a machine-readable counterpart (`meterbar cost
    /// --json`); quota windows are already the provider's own numbers.
    var exportsCostJSON: Bool {
        if case .receipt = self { return true }
        return false
    }

    static func entries(for snapshots: [ProviderSnapshot]) -> [ShareGalleryEntry] {
        guard !snapshots.isEmpty else { return [.receipt, .limitsPlaceholder] }
        return [.receipt] + snapshots.map(ShareGalleryEntry.limits)
    }
}

// MARK: - ShareGalleryLayout

/// Column math for the gallery grid.
///
/// Tiles are packed by `ProviderMasonryLayout`, which flows each column
/// independently — the captions under the cards wrap to different heights, and
/// a row-locked grid would pad every tile out to the tallest caption in its row.
/// This enum only decides how many columns that layout gets and how wide a card
/// preview ends up inside one, both of which are pure functions of the viewport.
enum ShareGalleryLayout {
    /// Below this, a 16:9 card preview stops being legible at a glance — the
    /// card's own hero number is only a third of its width — and the tile can no
    /// longer hold a labelled row of export buttons. The gallery is better off
    /// with one wide column than with two unreadable ones.
    static let minimumTileWidth: CGFloat = 420
    /// Two across. A third column only fits on a very wide window, and it buys
    /// the row nothing: the cards are 16:9, so a narrower column is a smaller
    /// card, and what the page is for is reading the card.
    static let maximumColumnCount = 2
    static let spacing = MeterBarTheme.Spacing.md

    /// Width available to the grid itself, once the page insets and the space
    /// reserved for a non-overlay scroller are taken out. Mirrors
    /// `SocialShareCardLayout.previewSize`, which reserves the same width for
    /// the same reason.
    static func contentWidth(
        viewportWidth: CGFloat,
        horizontalInsets: CGFloat,
        verticalScrollerWidth: CGFloat = SocialShareCardLayout.reservedVerticalScrollerWidth
    ) -> CGFloat {
        max(0, viewportWidth - horizontalInsets - verticalScrollerWidth)
    }

    static func columnCount(contentWidth: CGFloat) -> Int {
        let fitting = Int((contentWidth + spacing) / (minimumTileWidth + spacing))
        return max(1, min(maximumColumnCount, fitting))
    }

    /// The 16:9 preview inside a tile: the column width less the tile's own
    /// padding on both sides.
    static func previewSize(contentWidth: CGFloat, columnCount: Int) -> CGSize {
        let columnWidth = ProviderMasonryLayout.columnWidth(
            containerWidth: contentWidth,
            columnCount: columnCount,
            spacing: spacing
        )
        let width = max(0, columnWidth - MeterBarTheme.CardPadding.standard.value * 2)
        return CGSize(width: width, height: width / SocialShareCardLayout.aspectRatio)
    }
}
