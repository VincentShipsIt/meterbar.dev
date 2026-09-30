import AppKit
import MeterBarShared
import SwiftUI

// The Usage page's day-by-day list, extracted from UsageDashboardView.swift (R8 split).
// The stacked daily chart that used to sit above it is now the Usage page's single
// time series (`UsageTimeSeriesCard`).

struct DailyUsageBreakdownList: View {
  let dailyUsage: [DailyTokenUsage]

  @State private var expandedDayIDs: Set<Date> = []
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var days: [DailyProviderUsageDay] {
    let grouped = Dictionary(grouping: dailyUsage) { Calendar.current.startOfDay(for: $0.date) }
    return grouped.map { day, rows in
      DailyProviderUsageDay(date: day, providers: Self.providerSummaries(from: rows))
    }
    .filter { $0.totalTokens > 0 }
    .sorted { $0.date > $1.date }
  }

  var body: some View {
    ScrollView(.horizontal) {
      table
        .frame(minWidth: DailyUsageTableLayout.minimumWidth)
    }
    .fixedSize(horizontal: false, vertical: true)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
  }

  private var table: some View {
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
    // In-place table expansion on a flat tile — no per-row glass surface to
    // morph, so it keeps the move/opacity transition on the shared token,
    // gated by Reduce Motion.
    withAnimation(reduceMotion ? nil : MeterBarTheme.Motion.disclosure) {
      if expandedDayIDs.contains(dayID) {
        expandedDayIDs.remove(dayID)
      } else {
        expandedDayIDs.insert(dayID)
      }
    }
  }

  /// Static so the fold itself is reachable from tests without going through
  /// SwiftUI body evaluation — the saturation regression this guards lives in
  /// the arithmetic, not the view.
  static func providerSummaries(from rows: [DailyTokenUsage]) -> [DailyProviderUsageSummary] {
    let grouped = Dictionary(grouping: rows, by: \.provider)
    return grouped.map { provider, providerRows in
      DailyProviderUsageSummary(
        provider: provider,
        // Saturating (issue #575): these are cache rows whose own token fields
        // can already be saturated from an earlier fold, so a plain
        // `reduce(0, +)` across a provider's days would trap on re-render.
        inputTokens: SafeAccumulate.sum(providerRows.map(\.inputTokens)),
        outputTokens: SafeAccumulate.sum(providerRows.map(\.outputTokens)),
        cacheReadTokens: SafeAccumulate.sum(providerRows.map(\.cacheReadTokens)),
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
  static var minimumWidth: CGFloat {
    dayColumnMinWidth + sourceColumnWidth + 4 * metricColumnWidth + costColumnWidth
      + 6 * rowSpacing + 2 * MeterBarTheme.Spacing.md
  }
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
    .padding(.horizontal, MeterBarTheme.Spacing.md)
    .padding(.vertical, MeterBarTheme.Spacing.sm)
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

  // Saturating (issue #575): each provider summary's own totals are already
  // saturating sums, and combining two saturated summaries with a plain `+`
  // traps just the same. This recomputes on every Costs-page render.
  var inputTokens: Int {
    SafeAccumulate.sum(providers.map(\.inputTokens))
  }

  var outputTokens: Int {
    SafeAccumulate.sum(providers.map(\.outputTokens))
  }

  var cacheReadTokens: Int {
    SafeAccumulate.sum(providers.map(\.cacheReadTokens))
  }

  var totalTokens: Int {
    SafeAccumulate.sum(providers.map(\.totalTokens))
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

  /// Saturating (issue #575): all three fields are themselves saturating sums
  /// over cache rows, so any two of them at the bound trap a plain `+`.
  var totalTokens: Int {
    SafeAccumulate.sum([inputTokens, outputTokens, cacheReadTokens])
  }
}

struct DailyUsageDetailRow: View {
  let day: DailyProviderUsageDay
  let isExpanded: Bool
  let toggle: () -> Void

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

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
              .contentTransition(.symbolEffect(.replace))
              .animation(MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion), value: isExpanded)

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
        .padding(.horizontal, MeterBarTheme.Spacing.md)
        .padding(.vertical, MeterBarTheme.Spacing.sm)
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
        .padding(.bottom, MeterBarTheme.Spacing.sm)
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
    .padding(.horizontal, MeterBarTheme.Spacing.md)
    .padding(.vertical, MeterBarTheme.Spacing.xs)
  }

  private var providerShortName: String { provider.provider.shortName }
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

  private static let monthDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  static func medium(_ date: Date) -> String { mediumDate.string(from: date) }
  static func month(_ date: Date) -> String { month.string(from: date) }
  static func weekdayMonthDay(_ date: Date) -> String { weekdayMonthDay.string(from: date) }
  static func monthDay(_ date: Date) -> String { monthDay.string(from: date) }
}
