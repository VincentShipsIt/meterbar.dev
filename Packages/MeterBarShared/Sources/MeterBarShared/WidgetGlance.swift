import CoreGraphics

/// Type and layout vocabulary for the widget surfaces.
///
/// The widget used to be drawn as a shrunken popover card — account name as the
/// headline, quota window stacked beneath it, a hairline `ProgressView` with the
/// percentage demoted to a trailing caption, and a footer of 7–8pt chips. That
/// hierarchy is right for a card the pointer is already resting on and wrong for
/// something read at arm's length in under a second, so the widget gets its own
/// vocabulary rather than a scaled-down copy of the card's.
///
/// Four inversions separate a glance from a card:
/// 1. the usage number is the largest type, not the account name;
/// 2. there is no stacked quota subtitle competing with it;
/// 3. the bar is a capsule with real weight, not a hairline;
/// 4. status is carried by the bar's tint, so the card's separate status dot goes.
///
/// Only sizes and layout intent live here. Colors stay per-target — see the note
/// in `UsageStatus.swift` — so this package remains free of SwiftUI and can keep
/// serving `MeterBarCLI` at its lower deployment target.
public enum WidgetGlance {
    /// Nothing on a home screen is readable below this. The widget shipped 7pt
    /// and 8pt labels; every size below is measured against this floor.
    public static let legibilityFloor: CGFloat = 10

    /// A default `ProgressView` draws a ~4pt hairline. The widget bar has to read
    /// as a filled quantity from across a desk, so it never goes under this.
    public static let minimumBarHeight: CGFloat = 6

    public static func metrics(for family: WidgetPresentationFamily) -> WidgetGlanceMetrics {
        switch family {
        case .small:
            // One hero number in 150×150: the whole tile is the number.
            return WidgetGlanceMetrics(
                headlineSize: 30,
                titleSize: 12,
                captionSize: 10,
                iconSize: 16,
                barHeight: 8,
                rowSpacing: 4,
                stackSpacing: 8,
                contentPadding: 12
            )
        case .medium:
            return WidgetGlanceMetrics(
                headlineSize: 18,
                titleSize: 12,
                captionSize: 10,
                iconSize: 15,
                barHeight: 6,
                rowSpacing: 2,
                stackSpacing: 8,
                contentPadding: 12
            )
        case .large:
            // Same row rhythm as medium — a large widget is more rows, not bigger
            // ones — with a touch more breathing room at the edge.
            return WidgetGlanceMetrics(
                headlineSize: 18,
                titleSize: 12,
                captionSize: 10,
                iconSize: 15,
                barHeight: 6,
                rowSpacing: 2,
                stackSpacing: 8,
                contentPadding: 14
            )
        }
    }

    /// How the planned rows are arranged. The small family leads with one hero
    /// number and demotes the rest to a rail; anything wider stacks full rows.
    /// With no rows at all every family falls back to the stack so the empty
    /// state renders through a single path.
    public static func layout(
        for presentation: WidgetPresentation,
        family: WidgetPresentationFamily
    ) -> WidgetGlanceLayout {
        guard family == .small, let headline = presentation.rows.first else {
            return .rows(presentation.rows)
        }
        return .hero(headline, supporting: Array(presentation.rows.dropFirst()))
    }
}

/// The sizes one widget family draws at. Every number a widget view needs comes
/// from here, so the widget extension and the in-app preview cannot drift.
public struct WidgetGlanceMetrics: Equatable, Sendable {
    /// The usage number — the largest type on the surface.
    public let headlineSize: CGFloat
    /// The account name.
    public let titleSize: CGFloat
    /// Quota window, reset time, freshness.
    public let captionSize: CGFloat
    public let iconSize: CGFloat
    public let barHeight: CGFloat
    /// Between the lines inside one row.
    public let rowSpacing: CGFloat
    /// Between rows. Always greater than `rowSpacing` so rows read as separate
    /// units without needing a divider.
    public let stackSpacing: CGFloat
    public let contentPadding: CGFloat

    public init(
        headlineSize: CGFloat,
        titleSize: CGFloat,
        captionSize: CGFloat,
        iconSize: CGFloat,
        barHeight: CGFloat,
        rowSpacing: CGFloat,
        stackSpacing: CGFloat,
        contentPadding: CGFloat
    ) {
        self.headlineSize = headlineSize
        self.titleSize = titleSize
        self.captionSize = captionSize
        self.iconSize = iconSize
        self.barHeight = barHeight
        self.rowSpacing = rowSpacing
        self.stackSpacing = stackSpacing
        self.contentPadding = contentPadding
    }
}

public enum WidgetGlanceLayout: Equatable, Sendable {
    /// One row carries the surface; the others are reduced to a supporting rail.
    case hero(WidgetPresentationRow, supporting: [WidgetPresentationRow])
    /// Full-width rows stacked top to bottom.
    case rows([WidgetPresentationRow])
}
