import MeterBarShared
import SwiftUI

/// The Usage page's four headline numbers, all cut from one `UsageReport` so
/// they describe the same window. Before the merge only the tokens tile followed
/// the window picker; the share, cache and ratio tiles kept reading the full
/// scan with no sign that they had not moved.
struct UsageHeadlineStrip: View {
    struct Tile: Equatable {
        let title: String
        let value: String
        let caption: String
        let systemImage: String
        /// Spoken in place of `title`, for a title that leans on `$$$`.
        var accessibilityTitle: String?
    }

    let report: UsageReport

    /// One row of four. These are headline numbers meant to be read at a glance;
    /// the minimum leaves room for four tiles beside the insights column.
    ///
    /// Internal (not private) so the single-row requirement can be pinned by a
    /// test rather than re-litigated the next time a tile is added.
    static let columns = Array(
        repeating: GridItem(.flexible(minimum: 96), spacing: 12, alignment: .top),
        count: 4
    )

    static func tiles(for report: UsageReport) -> [Tile] {
        let window = report.selection.subtitle.lowercased()
        let headline = report.headline
        return [
            Tile(
                title: "Estimated cost",
                value: UsageFormat.cost(headline.costUSD),
                caption: "API rates, \(window)",
                systemImage: "dollarsign.circle"
            ),
            Tile(
                title: "Total tokens",
                value: UsageFormat.tokens(headline.totalTokens),
                caption: window,
                systemImage: "number"
            ),
            Tile(
                title: "Cache reads",
                value: headline.cacheReadShare.map(OptimizationInsights.percentString) ?? "—",
                caption: "of all tokens",
                systemImage: "arrow.triangle.2.circlepath"
            ),
            Tile(
                title: "$$$ model share",
                value: headline.premiumShare.map(OptimizationInsights.percentString) ?? "—",
                caption: "of known-model tokens",
                systemImage: "bolt.fill",
                accessibilityTitle: ModelTier.premium.costAccessibilityLabel
            ),
        ]
    }

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
            ForEach(Self.tiles(for: report), id: \.title) { tile in
                DashboardMetricTile(
                    title: tile.title,
                    value: tile.value,
                    caption: tile.caption,
                    systemImage: tile.systemImage,
                    accessibilityTitle: tile.accessibilityTitle
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}
