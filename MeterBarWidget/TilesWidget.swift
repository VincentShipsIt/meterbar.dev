import MeterBarShared
import SwiftUI
import WidgetKit

/// The popover's tiles on the desktop. Small is the tightest limit as one big
/// figure; medium puts up to three providers side by side, tightest first.
/// Every figure says "left" or "used", following the widget display mode.
struct TilesWidget: Widget {
    let kind: String = MeterBarWidgetKind.tiles

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            TilesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("MeterBar Tiles")
        .description("Your tightest limit first, the same tiles as the menu bar.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TilesWidgetEntryView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetFamily)
    private var family

    var body: some View {
        // Rows are ranked before the planner's row budget cuts them, so the
        // tightest provider survives however many are enabled. Both sizes read
        // the medium budget; the small tile shows its first row.
        let presentation = entry.presentation(for: .medium, rowOrdering: WidgetTileOrdering.tightestFirst)
        let rows = presentation.rows
        Group {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState, compact: family == .systemSmall)
            } else if family == .systemSmall, let row = rows.first {
                WidgetHeroTile(row: row)
            } else {
                HStack(spacing: 8) {
                    ForEach(rows.prefix(3)) { row in
                        WidgetMiniTile(row: row)
                    }
                }
            }
        }
        .padding(family == .systemSmall ? 14 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// The small widget: provider, the figure, and when it resets.
struct WidgetHeroTile: View {
    let row: WidgetPresentationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                WidgetProviderIcon(service: row.service, size: 16)
                Text(row.accountName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                WidgetHealthIndicator(health: row.health, size: 11)
            }
            Spacer(minLength: 0)
            Text(WidgetLocalizedContent.summaryText(for: row))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(row.isBlocked ? Color.red : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if row.drawsDepletingBar {
                WidgetGlanceBar(row: row, height: 6)
            }
            WidgetTileCaption(row: row)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accountName)
        .accessibilityValue(WidgetLocalizedContent.accessibilityValue(for: row))
    }
}

/// One provider in the medium widget, on its own inset tile.
struct WidgetMiniTile: View {
    let row: WidgetPresentationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                WidgetProviderIcon(service: row.service, size: 14)
                Spacer(minLength: 0)
                WidgetHealthIndicator(health: row.health, size: 10)
            }
            Spacer(minLength: 0)
            Text(WidgetLocalizedContent.compactSummaryText(for: row))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(row.isBlocked ? Color.red : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(row.accountName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            WidgetTileCaption(row: row)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accountName)
        .accessibilityValue(WidgetLocalizedContent.accessibilityValue(for: row, compact: true))
    }
}

/// Window and reset on one line ("Weekly · 2d 4h").
struct WidgetTileCaption: View {
    let row: WidgetPresentationRow

    var body: some View {
        HStack(spacing: 3) {
            Text(WidgetLocalizedContent.quotaTitle(for: row))
            if let resetTime = row.resetTime {
                Text(verbatim: "·")
                Text(resetTime, style: .relative)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
