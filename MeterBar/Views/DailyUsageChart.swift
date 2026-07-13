import AppKit
import MeterBarShared
import SwiftUI

// Daily usage chart + breakdown views extracted from UsageDashboardView.swift (R8 split). Pure move.

struct DailyUsageChart: View {
  let dailyUsage: [DailyTokenUsage]
  let daysToShow: Int

  private let barSpacing: CGFloat = 4
  private let labelHeight: CGFloat = 22
  private let legendHeight: CGFloat = 18

  // Precomputed once at init instead of on every SwiftUI body access. The
  // grouping + 30-day date arithmetic was previously re-run many times per
  // render (from body, visibleProviders, maxTokens, barWidth, barHeight).
  private let days: [DailyUsageDay]

  init(dailyUsage: [DailyTokenUsage], daysToShow: Int = 30) {
    self.dailyUsage = dailyUsage
    self.daysToShow = daysToShow
    self.days = Self.buildDays(from: dailyUsage, daysToShow: daysToShow)
  }

  private static let providerOrder: [ServiceType] = [.claudeCode, .codexCli, .cursor]

  private static func buildDays(
    from dailyUsage: [DailyTokenUsage],
    daysToShow: Int
  ) -> [DailyUsageDay] {
    let calendar = Calendar.current
    let normalizedDaysToShow = max(1, daysToShow)
    let endDate = calendar.startOfDay(for: Date())
    let startDate =
      calendar.date(byAdding: .day, value: -(normalizedDaysToShow - 1), to: endDate) ?? endDate
    let grouped = Dictionary(grouping: dailyUsage) { calendar.startOfDay(for: $0.date) }

    return (0..<normalizedDaysToShow).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
        return nil
      }

      let rows = grouped[date] ?? []
      let segments = providerOrder.compactMap { provider -> DailyUsageProviderSegment? in
        let providerRows = rows.filter { $0.provider == provider }
        let tokens = providerRows.reduce(0) { $0 + $1.totalTokens }
        guard tokens > 0 else { return nil }

        return DailyUsageProviderSegment(
          provider: provider,
          tokens: tokens,
          cost: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
        )
      }

      return DailyUsageDay(
        date: date,
        segments: segments,
        cost: rows.reduce(0) { $0 + $1.estimatedCostUSD }
      )
    }
  }

  private var visibleProviders: [ServiceType] {
    Self.providerOrder.filter { provider in
      days.contains { day in
        day.segments.contains { $0.provider == provider }
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if days.allSatisfy({ $0.totalTokens == 0 }) {
        Text("No token history found for the last 30 days.")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        legend

        GeometryReader { proxy in
          let width = barWidth(totalWidth: proxy.size.width)
          let chartHeight = max(40, proxy.size.height - labelHeight)

          VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: barSpacing) {
              ForEach(days) { day in
                StackedDailyUsageColumn(
                  day: day,
                  width: width,
                  height: barHeight(totalHeight: chartHeight, tokens: day.totalTokens),
                  maxHeight: chartHeight,
                  helpText: helpText(for: day),
                  colorForProvider: color(for:)
                )
              }
            }
            .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

            HStack(alignment: .top, spacing: barSpacing) {
              ForEach(days.indices, id: \.self) { index in
                DailyUsageDateLabel(
                  date: days[index].date,
                  width: width,
                  showsMonth: shouldShowMonth(at: index)
                )
              }
            }
            .frame(height: labelHeight, alignment: .topLeading)
          }
        }
      }
    }
  }

  private var legend: some View {
    HStack(spacing: 12) {
      ForEach(visibleProviders, id: \.self) { provider in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 2)
            .fill(color(for: provider))
            .frame(width: 8, height: 8)
          Text(provider.displayName)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }

      Spacer(minLength: 0)
    }
    .frame(height: legendHeight, alignment: .leading)
  }

  private var maxTokens: Int {
    max(days.map(\.totalTokens).max() ?? 1, 1)
  }

  private func barWidth(totalWidth: CGFloat) -> CGFloat {
    let gapsWidth = CGFloat(max(0, days.count - 1)) * barSpacing
    return max(4, (totalWidth - gapsWidth) / CGFloat(max(1, days.count)))
  }

  private func barHeight(totalHeight: CGFloat, tokens: Int) -> CGFloat {
    guard tokens > 0 else { return 2 }
    return max(4, totalHeight * CGFloat(tokens) / CGFloat(maxTokens))
  }

  private func shouldShowMonth(at index: Int) -> Bool {
    guard days.indices.contains(index) else { return false }
    if index == 0 { return true }

    return Calendar.current.component(.day, from: days[index].date) == 1
  }

  private func helpText(for day: DailyUsageDay) -> String {
    var lines = [
      DashboardDateFormat.medium(day.date),
      "\(UsageFormat.tokens(day.totalTokens)) tokens",
      UsageFormat.cost(day.cost),
    ]

    if day.segments.isEmpty {
      lines.append("No tracked provider usage")
    } else {
      lines.append("")
      for segment in day.segments {
        lines.append(
          "\(segment.provider.displayName): "
            + "\(UsageFormat.tokens(segment.tokens)) · \(UsageFormat.cost(segment.cost))"
        )
      }
    }

    return lines.joined(separator: "\n")
  }

  private func color(for provider: ServiceType) -> Color {
    MeterBarTheme.accent(for: provider)
  }
}

struct StackedDailyUsageColumn: View {
  let day: DailyUsageDay
  let width: CGFloat
  let height: CGFloat
  let maxHeight: CGFloat
  let helpText: String
  let colorForProvider: (ServiceType) -> Color

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)

      if day.totalTokens > 0 {
        VStack(spacing: 0) {
          ForEach(day.segments.reversed()) { segment in
            Rectangle()
              .fill(colorForProvider(segment.provider))
              .frame(height: segmentHeight(segment))
          }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: 3))
      } else {
        Capsule()
          .fill(.quaternary)
          .frame(width: width, height: 2)
      }
    }
    .frame(width: width, height: maxHeight, alignment: .bottom)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(day.chartAccessibilityLabel)
    .accessibilityValue(day.chartAccessibilityValue)
    .help(helpText)
  }

  private func segmentHeight(_ segment: DailyUsageProviderSegment) -> CGFloat {
    guard day.totalTokens > 0 else { return 0 }
    return max(1, height * CGFloat(segment.tokens) / CGFloat(day.totalTokens))
  }
}

struct DailyUsageDateLabel: View {
  let date: Date
  let width: CGFloat
  let showsMonth: Bool

  var body: some View {
    VStack(spacing: 0) {
      Text(dayText)
        .font(.system(size: 8, weight: .medium, design: .monospaced))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(showsMonth ? monthText : "")
        .font(.system(size: 7, weight: .medium))
        .foregroundColor(.secondary.opacity(0.75))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(width: width, height: 20, alignment: .top)
    .help(fullDateText)
  }

  private var dayText: String {
    String(Calendar.current.component(.day, from: date))
  }

  private var monthText: String {
    DashboardDateFormat.month(date)
  }

  private var fullDateText: String {
    DashboardDateFormat.medium(date)
  }
}

struct DailyUsageDay: Identifiable {
  var id: Date { date }
  let date: Date
  let segments: [DailyUsageProviderSegment]
  let cost: Double

  var totalTokens: Int {
    segments.reduce(0) { $0 + $1.tokens }
  }

  var chartAccessibilityLabel: String {
    DashboardDateFormat.medium(date)
  }

  var chartAccessibilityValue: String {
    var values = [
      "\(UsageFormat.tokens(totalTokens)) tokens",
      UsageFormat.cost(cost),
    ]
    values.append(contentsOf: segments.map { segment in
      "\(segment.provider.displayName) \(UsageFormat.tokens(segment.tokens)) tokens, "
        + UsageFormat.cost(segment.cost)
    })
    return values.joined(separator: ", ")
  }
}

struct DailyUsageProviderSegment: Identifiable {
  var id: ServiceType { provider }
  let provider: ServiceType
  let tokens: Int
  let cost: Double
}

struct DailyUsageBreakdownList: View {
  let dailyUsage: [DailyTokenUsage]

  @State private var expandedDayIDs: Set<Date> = []

  private var days: [DailyProviderUsageDay] {
    let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
    return grouped.map { day, rows in
      DailyProviderUsageDay(date: day, providers: providerSummaries(from: rows))
    }
    .filter { $0.totalTokens > 0 }
    .sorted { $0.date > $1.date }
  }

  var body: some View {
    VStack(spacing: 0) {
      DailyUsageTableHeader()

      Divider()

      if days.isEmpty {
        Text("No daily token history found.")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
      } else {
        LazyVStack(spacing: 0) {
          ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
            if index > 0 {
              Divider()
            }

            DailyUsageDetailRow(
              day: day,
              isExpanded: expandedDayIDs.contains(day.id),
              toggle: { toggleExpansion(for: day.id) }
            )
          }
        }
      }
    }
  }

  private func toggleExpansion(for dayID: Date) {
    withAnimation(.snappy(duration: 0.18)) {
      if expandedDayIDs.contains(dayID) {
        expandedDayIDs.remove(dayID)
      } else {
        expandedDayIDs.insert(dayID)
      }
    }
  }

  private func providerSummaries(from rows: [DailyTokenUsage]) -> [DailyProviderUsageSummary] {
    let grouped = Dictionary(grouping: rows, by: \.provider)
    return grouped.map { provider, providerRows in
      DailyProviderUsageSummary(
        provider: provider,
        inputTokens: providerRows.reduce(0) { $0 + $1.inputTokens },
        outputTokens: providerRows.reduce(0) { $0 + $1.outputTokens },
        cacheReadTokens: providerRows.reduce(0) { $0 + $1.cacheReadTokens },
        estimatedCostUSD: providerRows.reduce(0) { $0 + $1.estimatedCostUSD }
      )
    }
    .sorted { lhs, rhs in
      if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
        return lhs.totalTokens > rhs.totalTokens
      }
      return lhs.estimatedCostUSD > rhs.estimatedCostUSD
    }
  }
}

private enum DailyUsageTableLayout {
  static let rowSpacing: CGFloat = 10
  static let dayColumnMinWidth: CGFloat = 142
  static let sourceColumnWidth: CGFloat = 70
  static let metricColumnWidth: CGFloat = 76
  static let costColumnWidth: CGFloat = 72
}

struct DailyUsageTableHeader: View {
  var body: some View {
    HStack(spacing: DailyUsageTableLayout.rowSpacing) {
      Text("Day")
        .frame(
          minWidth: DailyUsageTableLayout.dayColumnMinWidth,
          maxWidth: .infinity,
          alignment: .leading
        )
      Text("Sources")
        .frame(width: DailyUsageTableLayout.sourceColumnWidth, alignment: .leading)
      DailyUsageColumnHeader("Input")
      DailyUsageColumnHeader("Output")
      DailyUsageColumnHeader("Cache")
      DailyUsageColumnHeader("Total")
      Text("Cost")
        .frame(width: DailyUsageTableLayout.costColumnWidth, alignment: .trailing)
    }
    .font(.caption2)
    .fontWeight(.semibold)
    .foregroundColor(.secondary)
    .textCase(.uppercase)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
  }
}

private struct DailyUsageColumnHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .frame(width: DailyUsageTableLayout.metricColumnWidth, alignment: .trailing)
  }
}

struct DailyProviderUsageDay: Identifiable {
  var id: Date { date }
  let date: Date
  let providers: [DailyProviderUsageSummary]

  var inputTokens: Int {
    providers.reduce(0) { $0 + $1.inputTokens }
  }

  var outputTokens: Int {
    providers.reduce(0) { $0 + $1.outputTokens }
  }

  var cacheReadTokens: Int {
    providers.reduce(0) { $0 + $1.cacheReadTokens }
  }

  var totalTokens: Int {
    providers.reduce(0) { $0 + $1.totalTokens }
  }

  var estimatedCostUSD: Double {
    providers.reduce(0) { $0 + $1.estimatedCostUSD }
  }
}

struct DailyProviderUsageSummary: Identifiable {
  var id: ServiceType { provider }
  let provider: ServiceType
  let inputTokens: Int
  let outputTokens: Int
  let cacheReadTokens: Int
  let estimatedCostUSD: Double

  var totalTokens: Int {
    inputTokens + outputTokens + cacheReadTokens
  }
}

struct DailyUsageDetailRow: View {
  let day: DailyProviderUsageDay
  let isExpanded: Bool
  let toggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: 8) {
          HStack(spacing: 7) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .fontWeight(.bold)
              .foregroundColor(.secondary)
              .frame(width: 12)

            Text(dateLabel(day.date))
              .font(.subheadline)
              .fontWeight(.semibold)
              .lineLimit(1)
          }
          .frame(
            minWidth: DailyUsageTableLayout.dayColumnMinWidth,
            maxWidth: .infinity,
            alignment: .leading
          )

          Text(providerCountLabel)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(width: DailyUsageTableLayout.sourceColumnWidth, alignment: .leading)

          DailyUsageMetricCell(value: UsageFormat.tokens(day.inputTokens))
          DailyUsageMetricCell(value: UsageFormat.tokens(day.outputTokens))
          DailyUsageMetricCell(value: UsageFormat.tokens(day.cacheReadTokens))
          DailyUsageMetricCell(value: UsageFormat.tokens(day.totalTokens), isPrimary: true)
          DailyUsageMetricCell(
            value: UsageFormat.cost(day.estimatedCostUSD),
            width: DailyUsageTableLayout.costColumnWidth,
            isPrimary: true
          )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilitySummary)
      .accessibilityHint(isExpanded ? "Collapse day details" : "Show day details")
      .accessibilityAction(named: Text(isExpanded ? "Collapse" : "Expand"), toggle)

      if isExpanded {
        VStack(spacing: 0) {
          ForEach(day.providers) { provider in
            DailyProviderUsageSummaryRow(provider: provider)
          }
        }
        .padding(.bottom, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  private var providerCountLabel: String {
    let count = day.providers.count
    return count == 1 ? "1 source" : "\(count) sources"
  }

  private var accessibilitySummary: String {
    "\(dateLabel(day.date)), \(UsageFormat.tokens(day.totalTokens)) tokens, "
      + "\(UsageFormat.cost(day.estimatedCostUSD))"
  }

  private func dateLabel(_ date: Date) -> String {
    DashboardDateFormat.weekdayMonthDay(date)
  }
}

struct DailyProviderUsageSummaryRow: View {
  let provider: DailyProviderUsageSummary

  var body: some View {
    HStack(spacing: DailyUsageTableLayout.rowSpacing) {
      HStack(spacing: 7) {
        Spacer()
          .frame(width: 19)

        ProviderLogoView(
          kind: .forService(provider.provider),
          size: 13,
          foregroundColor: MeterBarTheme.accent(for: provider.provider)
        )
        Text(provider.provider.displayName)
          .font(.caption)
          .fontWeight(.semibold)
          .lineLimit(1)
      }
      .frame(
        minWidth: DailyUsageTableLayout.dayColumnMinWidth, maxWidth: .infinity, alignment: .leading)

      Text(providerShortName)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .frame(width: DailyUsageTableLayout.sourceColumnWidth, alignment: .leading)

      DailyUsageMetricCell(value: UsageFormat.tokens(provider.inputTokens))
      DailyUsageMetricCell(value: UsageFormat.tokens(provider.outputTokens))
      DailyUsageMetricCell(value: UsageFormat.tokens(provider.cacheReadTokens))
      DailyUsageMetricCell(value: UsageFormat.tokens(provider.totalTokens))
      DailyUsageMetricCell(
        value: UsageFormat.cost(provider.estimatedCostUSD),
        width: DailyUsageTableLayout.costColumnWidth
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
  }

  private var providerShortName: String {
    switch provider.provider {
    case .claudeCode:
      return "Claude"
    case .codexCli:
      return "Codex"
    case .cursor:
      return "Cursor"
    }
  }
}

private struct DailyUsageMetricCell: View {
  let value: String
  var width = DailyUsageTableLayout.metricColumnWidth
  var isPrimary = false

  var body: some View {
    Text(value)
      .font(.caption)
      .fontWeight(isPrimary ? .semibold : .regular)
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .foregroundColor(isPrimary ? .primary : .secondary)
      .frame(width: width, alignment: .trailing)
  }
}

/// Cached date formatters for the dashboard. `DateFormatter` is expensive to
/// allocate, so the daily chart/labels (30+ per render) share these instances.
enum DashboardDateFormat {
  private static let mediumDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let month: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM"
    return formatter
  }()

  private static let weekdayMonthDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, MMM d"
    return formatter
  }()

  static func medium(_ date: Date) -> String { mediumDate.string(from: date) }
  static func month(_ date: Date) -> String { month.string(from: date) }
  static func weekdayMonthDay(_ date: Date) -> String { weekdayMonthDay.string(from: date) }
}
