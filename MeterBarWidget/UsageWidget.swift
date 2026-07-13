import MeterBarShared
import WidgetKit
import SwiftUI

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

    var rows: [WidgetUsageRow] {
        let accountServices = Set(accountMetrics.map { $0.metrics.service })
        let accountRows = accountMetrics.map {
            WidgetUsageRow(id: $0.id.uuidString, name: $0.name, metrics: $0.metrics)
        }
        let providerRows = metrics
            .filter { !accountServices.contains($0.key) }
            .map { WidgetUsageRow(id: $0.key.rawValue, name: $0.key.displayName, metrics: $0.value) }
        return (accountRows + providerRows).sorted {
            ($0.metrics.service.sortOrder, $0.name) < ($1.metrics.service.sortOrder, $1.name)
        }
    }
}

struct WidgetUsageRow: Identifiable {
    let id: String
    let name: String
    let metrics: UsageMetrics
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
            accountMetrics: []
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: SharedMetricsStore.loadMetrics(),
            accountMetrics: SharedMetricsStore.loadAccountMetrics()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let cachedMetrics = SharedMetricsStore.loadMetrics()
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: cachedMetrics,
            accountMetrics: SharedMetricsStore.loadAccountMetrics()
        )

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct UsageWidgetEntryView: View {
    var entry: UsageWidgetEntry
    @Environment(\.widgetFamily) var family

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
        VStack(alignment: .leading, spacing: 6) {
            if entry.rows.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(entry.rows.prefix(3))) { row in
                    ServiceMiniView(row: row)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceMiniView: View {
    let row: WidgetUsageRow

    var body: some View {
        HStack(spacing: 6) {
            Image(row.metrics.service.assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)

            Text(row.name)
                .font(.caption2)
                .lineLimit(1)

            if let weeklyLimit = row.metrics.weeklyLimit {
                ProgressView(value: weeklyLimit.clampedUsed, total: weeklyLimit.clampedTotal)
                    .tint(weeklyLimit.statusColor.color)
                Text(limitSummary(weeklyLimit))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            WidgetStatusIndicator(status: row.metrics.overallStatus)
        }
    }

    private func limitSummary(_ limit: UsageLimit) -> String {
        if row.metrics.service == .openRouter {
            return String(format: "$%.2f", max(0, limit.total - limit.used))
        }
        return limit.percentageText
    }
}

struct MediumWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.rows.isEmpty {
                Text("No services connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(entry.rows) { row in
                    ServiceCompactView(row: row)
                }
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
        VStack(alignment: .leading, spacing: 0) {
            if entry.rows.isEmpty {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("No services connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = Array(entry.rows.prefix(7))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ServiceCompactView(row: row)
                    if index < rows.count - 1 {
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceCompactView: View {
    let row: WidgetUsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(row.metrics.service.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                Text(row.name)
                    .font(.subheadline)
                    .bold()
                Spacer()
                WidgetStatusIndicator(status: row.metrics.overallStatus)
            }

            if let weeklyLimit = row.metrics.weeklyLimit {
                HStack {
                    ProgressView(value: weeklyLimit.clampedUsed, total: weeklyLimit.clampedTotal)
                        .tint(weeklyLimit.statusColor.color)
                    Text(limitSummary(weeklyLimit))
                        .font(.caption)
                }
            }
        }
    }

    private func limitSummary(_ limit: UsageLimit) -> String {
        if row.metrics.service == .openRouter {
            return String(format: "$%.2f left", max(0, limit.total - limit.used))
        }
        return limit.percentageText
    }
}

struct ServiceDetailView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetProviderIcon(service: metrics.service, size: 20)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            if let sessionLimit = metrics.sessionLimit {
                LimitDetailView(
                    title: metrics.service == .openRouter ? "Key limit" : "Session",
                    limit: sessionLimit,
                    currency: metrics.service == .openRouter
                )
            }

            if let weeklyLimit = metrics.weeklyLimit {
                LimitDetailView(
                    title: metrics.service == .openRouter ? "Account credits" : "Weekly",
                    limit: weeklyLimit,
                    currency: metrics.service == .openRouter
                )
            }

            if let codeReviewLimit = metrics.codeReviewLimit {
                LimitDetailView(title: "Code Review", limit: codeReviewLimit)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct LimitDetailView: View {
    let title: String
    let limit: UsageLimit
    var currency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(limit.percentageText)
                    .font(.caption)
                    .bold()
            }

            ProgressView(value: limit.clampedUsed, total: limit.clampedTotal)
                .tint(limit.statusColor.color)

            Text(currency ? currencyText : "\(formatNumber(limit.used)) / \(limit.isEstimated ? "~" : "")\(formatNumber(limit.total))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var currencyText: String {
        "$\(String(format: "%.2f", limit.used)) spent / $\(String(format: "%.2f", limit.total))"
    }

    private func formatNumber(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        return String(format: "%.0f", value)
    }
}

struct WidgetProviderIcon: View {
    let service: ServiceType
    let size: CGFloat

    var body: some View {
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

struct WidgetStatusIndicator: View {
    let status: UsageStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}
