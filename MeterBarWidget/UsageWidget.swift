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

    var sortedServices: [ServiceType] {
        metrics.keys.sorted { $0.sortOrder < $1.sortOrder }
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
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: SharedMetricsStore.loadMetrics()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let cachedMetrics = SharedMetricsStore.loadMetrics()
        let entry = UsageWidgetEntry(
            date: Date(),
            metrics: cachedMetrics
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
            if entry.metrics.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(entry.sortedServices.prefix(3), id: \.self) { service in
                    if let metrics = entry.metrics[service] {
                        ServiceMiniView(metrics: metrics)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ServiceMiniView: View {
    let metrics: UsageMetrics

    var body: some View {
        HStack(spacing: 6) {
            WidgetProviderIcon(service: metrics.service, size: 14)

            if let weeklyLimit = metrics.weeklyLimit {
                ProgressView(value: weeklyLimit.clampedUsed, total: weeklyLimit.clampedTotal)
                    .tint(weeklyLimit.statusColor.color)
                Text(limitSummary(weeklyLimit))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            WidgetStatusIndicator(status: metrics.overallStatus)
        }
    }

    private func limitSummary(_ limit: UsageLimit) -> String {
        if metrics.service == .openRouter {
            return String(format: "$%.2f", max(0, limit.total - limit.used))
        }
        return limit.percentageText
    }
}

struct MediumWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.metrics.isEmpty {
                Text("No services connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(entry.sortedServices, id: \.self) { service in
                    if let metrics = entry.metrics[service] {
                        ServiceCompactView(metrics: metrics)
                    }
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
            if entry.metrics.isEmpty {
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
                let services = Array(entry.sortedServices.prefix(7))
                ForEach(Array(services.enumerated()), id: \.element) { index, service in
                    if let metrics = entry.metrics[service] {
                        ServiceCompactView(metrics: metrics)
                        if index < services.count - 1 {
                            Spacer()
                        }
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
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                WidgetProviderIcon(service: metrics.service, size: 18)
                Text(metrics.service.displayName)
                    .font(.subheadline)
                    .bold()
                Spacer()
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            if let weeklyLimit = metrics.weeklyLimit {
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
        if metrics.service == .openRouter {
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
