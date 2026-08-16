import MeterBarShared
import SwiftUI
import WidgetKit

struct BurnDownWidget: Widget {
    let kind: String = MeterBarWidgetKind.burnDown

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BurnDownWidgetProvider()) { entry in
            BurnDownWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(
            String(localized: "widget.burndown.name", defaultValue: "MeterBar Burn Down")
        )
        .description("widget.burndown.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BurnDownWidgetEntry: TimelineEntry {
    let date: Date
    let metrics: [ServiceType: UsageMetrics]
    let accountMetrics: [AccountUsageSnapshot]
    let preferences: WidgetPreferences

    func presentation(for family: WidgetPresentationFamily) -> WidgetBurnDownPresentation {
        WidgetBurnDownPlanner.makePresentation(
            metrics: metrics,
            accountMetrics: accountMetrics,
            preferences: preferences,
            family: family,
            now: date
        )
    }
}

struct BurnDownWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BurnDownWidgetEntry {
        let now = Date()
        return BurnDownWidgetEntry(
            date: now,
            metrics: [
                .claudeCode: placeholderMetrics(
                    service: .claudeCode,
                    used: 72,
                    resetTime: now.addingTimeInterval(2.5 * 24 * 60 * 60)
                ),
                .codexCli: placeholderMetrics(
                    service: .codexCli,
                    used: 38,
                    resetTime: now.addingTimeInterval(4 * 24 * 60 * 60)
                ),
                .grok: placeholderMetrics(
                    service: .grok,
                    used: 47,
                    resetTime: now.addingTimeInterval(3 * 24 * 60 * 60)
                ),
                .openRouter: placeholderMetrics(
                    service: .openRouter,
                    used: 32,
                    resetTime: now.addingTimeInterval(18 * 24 * 60 * 60)
                )
            ],
            accountMetrics: [],
            preferences: .defaults
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BurnDownWidgetEntry) -> Void) {
        completion(currentEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BurnDownWidgetEntry>) -> Void) {
        let now = Date()
        let entry = currentEntry(at: now)
        let presentation = entry.presentation(for: presentationFamily(context.family))
        let nextUpdate = WidgetBurnDownTimeline.nextUpdateDate(
            after: now,
            presentation: presentation
        )
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry(at date: Date) -> BurnDownWidgetEntry {
        BurnDownWidgetEntry(
            date: date,
            metrics: SharedMetricsStore.loadMetrics(),
            accountMetrics: SharedMetricsStore.loadAccountMetrics(),
            preferences: WidgetPreferencesStore().preferences
        )
    }

    private func presentationFamily(_ family: WidgetFamily) -> WidgetPresentationFamily {
        family == .systemSmall ? .small : .medium
    }

    private func placeholderMetrics(
        service: ServiceType,
        used: Double,
        resetTime: Date
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(
                used: used,
                total: 100,
                resetTime: resetTime,
                windowSeconds: 7 * 24 * 60 * 60
            ),
            lastUpdated: Date()
        )
    }
}

struct BurnDownWidgetEntryView: View {
    let entry: BurnDownWidgetEntry

    @Environment(\.widgetFamily)
    private var family

    var body: some View {
        switch family {
        case .systemMedium:
            BurnDownWidgetSurface(entry: entry, family: .medium)
        default:
            BurnDownWidgetSurface(entry: entry, family: .small)
        }
    }
}

struct BurnDownWidgetSurface: View {
    let entry: BurnDownWidgetEntry
    let family: WidgetPresentationFamily

    private var presentation: WidgetBurnDownPresentation {
        entry.presentation(for: family)
    }

    private var metrics: WidgetGlanceMetrics {
        WidgetGlance.metrics(for: family)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.stackSpacing) {
            if let emptyState = presentation.emptyState {
                WidgetEmptyStateView(state: emptyState, compact: family == .small)
            } else if family == .small {
                if let row = presentation.rows.first {
                    BurnDownWidgetRowView(row: row, entryDate: entry.date, isCompact: false)
                }
                WidgetOverflowView(hiddenRowCount: presentation.hiddenRowCount, metrics: metrics)
            } else {
                HStack(alignment: .top, spacing: metrics.stackSpacing) {
                    ForEach(presentation.rows) { row in
                        BurnDownWidgetRowView(row: row, entryDate: entry.date, isCompact: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if row.id != presentation.rows.last?.id {
                            Divider()
                        }
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

struct BurnDownWidgetRowView: View {
    let row: WidgetBurnDownRow
    let entryDate: Date
    let isCompact: Bool

    private var metrics: WidgetGlanceMetrics {
        WidgetGlance.metrics(for: isCompact ? .medium : .small)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing + 2) {
            HStack(spacing: metrics.rowSpacing * 2) {
                WidgetProviderIcon(service: row.service, size: metrics.iconSize)
                Text(row.accountName)
                    .font(.system(size: metrics.titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: metrics.rowSpacing)
                WidgetHealthIndicator(health: row.health, size: metrics.captionSize)
            }

            Text(WidgetLocalizedContent.burnDownCountdownTitle(for: row))
                .font(.system(size: metrics.captionSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            countdown

            Label(WidgetLocalizedContent.burnDownStageText(for: row), systemImage: row.stage.symbolName)
                .font(.system(size: metrics.captionSize, weight: .semibold))
                .foregroundStyle(stageColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: metrics.rowSpacing) {
                Text(WidgetLocalizedContent.quotaTitle(for: row.row))
                if let limit = row.row.limit {
                    Text("·")
                    Text(LocalizedUsageFormat.percentLeft(limit))
                }
            }
            .font(.system(size: metrics.captionSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accountName)
        .accessibilityValue(WidgetLocalizedContent.burnDownAccessibilityValue(for: row))
    }

    private var stageColor: Color {
        row.isExhausted ? .red : row.stage.color
    }

    @ViewBuilder private var countdown: some View {
        if let target = row.countdownTarget, target > entryDate {
            Text(target, style: .timer)
                .font(.system(size: metrics.headlineSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        } else {
            Text(WidgetLocalizedContent.burnDownCountdownText(for: row))
                .font(.system(size: metrics.headlineSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }
}

private extension WidgetBurnDownStage {
    var color: Color {
        switch self {
        case .onPace, .unavailable:
            return .secondary
        case .reserve:
            return .green
        case .deficit:
            return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .onPace:
            return "equal.circle.fill"
        case .reserve:
            return "arrow.down.right.circle.fill"
        case .deficit:
            return "arrow.up.right.circle.fill"
        case .unavailable:
            return "questionmark.circle"
        }
    }
}
