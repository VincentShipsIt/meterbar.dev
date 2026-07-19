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
    let kind: String = "UsageWidget"

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

struct SmallWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        let presentation = entry.presentation(for: .small)
        VStack(alignment: .leading, spacing: 6) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState, compact: true)
            } else {
                ForEach(presentation.rows) { row in
                    ServiceMiniView(row: row)
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceMiniView: View {
    let row: WidgetPresentationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                WidgetProviderIcon(service: row.service, size: 13)

                VStack(alignment: .leading, spacing: 0) {
                    Text(row.accountName)
                        .font(.caption2)
                        .lineLimit(1)
                    Text(row.quotaTitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                if let progressValue = row.progressValue,
                   let progressTotal = row.progressTotal {
                    ProgressView(value: progressValue, total: progressTotal)
                        .tint(row.usageStatus?.color ?? .secondary)
                }

                Text(row.compactSummaryText)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                WidgetHealthIndicator(row: row)
            }

            WidgetRowDetails(row: row)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MediumWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        let presentation = entry.presentation(for: .medium)
        VStack(alignment: .leading, spacing: 8) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState)
            } else {
                ForEach(presentation.rows) { row in
                    ServiceCompactView(row: row)
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LargeWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        let presentation = entry.presentation(for: .large)
        VStack(alignment: .leading, spacing: 0) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState)
            } else {
                ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                    ServiceCompactView(row: row)
                    if index < presentation.rows.count - 1 {
                        Spacer()
                    }
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceCompactView: View {
    let row: WidgetPresentationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                WidgetProviderIcon(service: row.service, size: 18)
                Text(row.accountName)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(1)
                Text(row.quotaTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                WidgetHealthIndicator(row: row)
            }

            if let progressValue = row.progressValue,
               let progressTotal = row.progressTotal {
                HStack {
                    ProgressView(value: progressValue, total: progressTotal)
                        .tint(row.usageStatus?.color ?? .secondary)
                    Text(row.summaryText)
                        .font(.caption)
                }
            } else {
                Text(row.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WidgetRowDetails(row: row)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WidgetRowDetails: View {
    let row: WidgetPresentationRow

    var body: some View {
        if row.resetTime != nil || row.freshnessDate != nil {
            HStack(spacing: 6) {
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
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
    }
}

struct WidgetHealthIndicator: View {
    let row: WidgetPresentationRow

    var body: some View {
        switch row.health {
        case .healthy:
            if let status = row.usageStatus {
                WidgetStatusIndicator(status: status)
                    .accessibilityLabel("Current usage")
            }
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityLabel("Stale usage data")
        case .unavailable:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Usage unavailable")
        }
    }
}

struct WidgetOverflowView: View {
    let hiddenRowCount: Int

    var body: some View {
        if hiddenRowCount > 0 {
            Label("+\(hiddenRowCount) more", systemImage: "ellipsis.circle")
                .font(.caption2)
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
        if service == .openRouter || service == .grok {
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
struct WidgetStatusIndicator: View {
    let status: UsageStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}
