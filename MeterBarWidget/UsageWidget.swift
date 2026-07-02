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

// MARK: - Shared Data Store (simplified for Widget)

class SharedDataStore {
    static let shared = SharedDataStore()

    private let appGroupIdentifier = "group.dev.shipshit.meterbar"
    private let metricsKey = "cached_usage_metrics"

    private var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    func loadMetrics() -> [ServiceType: UsageMetrics] {
        guard let containerURL = containerURL else { return [:] }

        let fileURL = containerURL.appendingPathComponent("\(metricsKey).json")

        // Tolerant per-entry decode via the shared codec: an unknown service
        // key or malformed entry drops that entry, not the whole cache — so a
        // cache written by an older build (e.g. with a removed provider) still
        // renders the providers that remain.
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return MetricsCodec.decode(data)
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
            metrics: SharedDataStore.shared.loadMetrics()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let cachedMetrics = SharedDataStore.shared.loadMetrics()
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
            Image(metrics.service.assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)

            if let weeklyLimit = metrics.weeklyLimit {
                ProgressView(value: weeklyLimit.clampedUsed, total: weeklyLimit.clampedTotal)
                    .tint(weeklyLimit.statusColor.color)
                Text("\(Int(weeklyLimit.percentage))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            WidgetStatusIndicator(status: metrics.overallStatus)
        }
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
                Image(metrics.service.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
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
                    Text("\(Int(weeklyLimit.percentage))%")
                        .font(.caption)
                }
            }
        }
    }
}

struct ServiceDetailView: View {
    let metrics: UsageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(metrics.service.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(metrics.service.displayName)
                    .font(.headline)
                Spacer()
                WidgetStatusIndicator(status: metrics.overallStatus)
            }

            if let sessionLimit = metrics.sessionLimit {
                LimitDetailView(title: "Session", limit: sessionLimit)
            }

            if let weeklyLimit = metrics.weeklyLimit {
                LimitDetailView(title: "Weekly", limit: weeklyLimit)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text("\(Int(limit.percentage))%")
                    .font(.caption)
                    .bold()
            }

            ProgressView(value: limit.clampedUsed, total: limit.clampedTotal)
                .tint(limit.statusColor.color)

            Text("\(formatNumber(limit.used)) / \(formatNumber(limit.total))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        return String(format: "%.0f", value)
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
