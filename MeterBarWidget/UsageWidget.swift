import MeterBarShared
import SwiftUI
import WidgetKit

// MARK: - Status Colors (widget presentation for the shared UsageStatus)

extension UsageStatus {
    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Widget

struct UsageWidget: Widget {
    let kind: String = MeterBarWidgetKind.usage

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("MeterBar")
        .description("Track your AI coding assistant usage limits")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let metrics: [ServiceType: UsageMetrics]
    let accountMetrics: [AccountUsageSnapshot]
    let preferences: WidgetPreferences

    func presentation(for family: WidgetPresentationFamily) -> WidgetPresentation {
        WidgetPresentationPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: accountMetrics,
            preferences: preferences,
            family: family,
            now: date
        )
    }
}

struct UsageWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: Date(),
            metrics: [
                .codexCli: UsageMetrics(
                    service: .codexCli,
                    weeklyLimit: UsageLimit(used: 30, total: 100, resetTime: nil)
                ),
                .cursor: UsageMetrics(
                    service: .cursor,
                    weeklyLimit: UsageLimit(used: 50, total: 100, resetTime: nil)
                ),
                .claudeCode: UsageMetrics(
                    service: .claudeCode,
                    weeklyLimit: UsageLimit(used: 90, total: 100, resetTime: nil)
                )
            ],
            accountMetrics: [],
            preferences: .defaults
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let entry = currentEntry()

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func currentEntry() -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: Date(),
            metrics: SharedMetricsStore.loadMetrics(),
            accountMetrics: SharedMetricsStore.loadAccountMetrics(),
            preferences: WidgetPreferencesStore().preferences
        )
    }
}

struct UsageWidgetEntryView: View {
    var entry: UsageWidgetEntry
    @Environment(\.widgetFamily)
    var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

/// Small is one number. The three stacked mini-cards it used to draw were the
/// popover's list shrunk past the point of being readable inside 150×150.
struct SmallWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        let presentation = entry.presentation(for: .small)
        let metrics = WidgetGlance.metrics(for: .small)
        VStack(alignment: .leading, spacing: metrics.stackSpacing) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState, compact: true)
            } else {
                switch WidgetGlance.layout(for: presentation, family: .small) {
                case let .hero(headline, supporting):
                    WidgetGlanceHero(row: headline, metrics: metrics)
                    WidgetGlanceRail(rows: supporting, metrics: metrics)
                case let .rows(rows):
                    ForEach(rows) { row in
                        WidgetGlanceRow(row: row, metrics: metrics)
                    }
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount, metrics: metrics)
            }
        }
        .padding(metrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct MediumWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        WidgetGlanceStack(entry: entry, family: .medium)
    }
}

struct LargeWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        WidgetGlanceStack(entry: entry, family: .large)
    }
}

/// Medium and large are the same surface with a different row budget, so they
/// share one body rather than two copies that drift.
struct WidgetGlanceStack: View {
    let entry: UsageWidgetEntry
    let family: WidgetPresentationFamily

    var body: some View {
        let presentation = entry.presentation(for: family)
        let metrics = WidgetGlance.metrics(for: family)
        VStack(alignment: .leading, spacing: metrics.stackSpacing) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState)
            } else {
                if case let .rows(rows) = WidgetGlance.layout(for: presentation, family: family) {
                    ForEach(rows) { row in
                        WidgetGlanceRow(row: row, metrics: metrics)
                    }
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount, metrics: metrics)
                // Rows hug the top and keep an even rhythm instead of being
                // spread apart to fill whatever height the family happens to be.
                Spacer(minLength: 0)
            }
        }
        .padding(metrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Glance rows

/// One provider, read at arm's length: the number leads, the account name
/// supports it, and the bar's tint carries status so no separate dot is needed.
struct WidgetGlanceRow: View {
    let row: WidgetPresentationRow
    let metrics: WidgetGlanceMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: metrics.rowSpacing * 2) {
                WidgetProviderIcon(service: row.service, size: metrics.iconSize)
                Text(row.accountName)
                    .font(.system(size: metrics.titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: metrics.rowSpacing)
                WidgetHealthIndicator(health: row.health, size: metrics.captionSize)
                Text(row.summaryText)
                    .font(.system(size: metrics.headlineSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            WidgetGlanceBar(row: row, height: metrics.barHeight)
            WidgetGlanceCaption(row: row, size: metrics.captionSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accountName)
        .accessibilityValue(row.accessibilityValueText)
    }
}

/// The small family's single row: the number takes the tile, everything else
/// sits under it.
struct WidgetGlanceHero: View {
    let row: WidgetPresentationRow
    let metrics: WidgetGlanceMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: metrics.rowSpacing * 2) {
                WidgetProviderIcon(service: row.service, size: metrics.iconSize)
                Text(row.accountName)
                    .font(.system(size: metrics.titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: metrics.rowSpacing)
                WidgetHealthIndicator(health: row.health, size: metrics.captionSize)
            }

            Text(row.summaryText)
                .font(.system(size: metrics.headlineSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            WidgetGlanceBar(row: row, height: metrics.barHeight)
            WidgetGlanceCaption(row: row, size: metrics.captionSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accountName)
        .accessibilityValue(row.accessibilityValueText)
    }
}

/// Everything the hero displaced, reduced to one line each: enough to know the
/// other accounts are fine, not enough to compete with the number above.
struct WidgetGlanceRail: View {
    let rows: [WidgetPresentationRow]
    let metrics: WidgetGlanceMetrics

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(rows) { row in
                    HStack(spacing: metrics.rowSpacing) {
                        WidgetProviderIcon(service: row.service, size: metrics.captionSize)
                        Text(row.accountName)
                            .font(.system(size: metrics.captionSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: metrics.rowSpacing)
                        Text(row.compactSummaryText)
                            .font(.system(size: metrics.captionSize, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(row.usageStatus?.color ?? .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accountName)
                    .accessibilityValue(row.compactAccessibilityValueText)
                }
            }
        }
    }
}

/// A capsule with weight rather than a `ProgressView` hairline, tinted by the
/// quota band so status needs no second glyph.
struct WidgetGlanceBar: View {
    let row: WidgetPresentationRow
    let height: CGFloat

    private var fraction: Double {
        guard let value = row.progressValue, let total = row.progressTotal, total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                let filled = proxy.size.width * fraction
                if filled > 0 {
                    Capsule(style: .continuous)
                        .fill(row.usageStatus?.color ?? Color.secondary)
                        // A sliver still has to read as a capsule, not a dot.
                        .frame(width: max(height, filled))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Quota window, reset and freshness on one line — the metadata the card stacked
/// under the account name, moved out of the headline's way.
struct WidgetGlanceCaption: View {
    let row: WidgetPresentationRow
    let size: CGFloat

    var body: some View {
        HStack(spacing: size / 2) {
            Text(row.quotaTitle)
            if let resetTime = row.resetTime {
                Label {
                    Text(resetTime, style: .relative)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            if let freshnessDate = row.freshnessDate {
                Label {
                    Text(freshnessDate, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Only the states the bar cannot express. A healthy row's status is already the
/// bar's tint, so it draws nothing here.
struct WidgetHealthIndicator: View {
    let health: WidgetDataHealth
    let size: CGFloat

    var body: some View {
        switch health {
        case .healthy:
            EmptyView()
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: size))
                .foregroundStyle(.orange)
                .accessibilityLabel(label)
        case .unavailable:
            Image(systemName: "xmark.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .accessibilityLabel(label)
        }
    }

    /// The badge and the row's spoken value read the same phrase out of
    /// `WidgetDataHealth`, so they cannot end up describing one state two ways.
    /// A healthy row draws no glyph, so it never reaches this.
    private var label: String {
        health.accessibilityDescription ?? ""
    }
}

struct WidgetOverflowView: View {
    let hiddenRowCount: Int
    let metrics: WidgetGlanceMetrics

    var body: some View {
        if hiddenRowCount > 0 {
            Label("+\(hiddenRowCount) more", systemImage: "ellipsis.circle")
                .font(.system(size: metrics.captionSize))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(hiddenRowCount) more usage rows")
        }
    }
}

struct WidgetEmptyStateView: View {
    let state: WidgetPresentationEmptyState
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 4) {
            if !compact {
                Image(systemName: state == .noSelection ? "slider.horizontal.3" : "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(state == .noSelection ? Color.secondary : Color.orange)
            }
            Text(state.title)
                .font(.caption)
                .bold()
            Text(state.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(compact ? .leading : .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .topLeading : .center)
    }
}

struct WidgetProviderIcon: View {
    let service: ServiceType
    let size: CGFloat

    var body: some View {
        // OpenRouter has no shipped logo yet, so it keeps the SF Symbol. Grok's
        // asset is a template imageset rather than the full-color logos the
        // others ship, since its mark is monochrome and has to hold up against
        // the widget's appearance-following background.
        if service == .openRouter {
            Image(systemName: service.iconName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size, height: size)
        } else {
            Image(service.assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
