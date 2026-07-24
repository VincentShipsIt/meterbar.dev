import MeterBarShared
import SwiftUI

/// The "Optimize" dashboard page (#72): an analytics/UI layer over the same
/// local `CostSummary` the Costs page already renders. It surfaces where tokens
/// go (by model and by usage origin), a handful of leanness KPIs, a derived
/// optimization score, and plain-English recommendations.
///
/// Everything shown here is computed on-device by `OptimizationInsights` from
/// token totals, model names, and workflow metadata only — no prompt contents,
/// nothing uploaded. Lives in its own file (never inside `UsageDashboardView`)
/// per the dashboard view-split convention.
struct OptimizeInsightsView: View {
  @StateObject private var costTracker = CostTracker.shared
  @StateObject private var providerVisibility = ProviderVisibilityStore.shared

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  /// 7/30-day window for the token-burn chart.
  @State private var chartDays = 30

  private var visibleSummary: CostSummary? {
    costTracker.costSummary?.filtered(to: providerVisibility.enabledServices)
  }

  private var insights: OptimizationInsights? {
    visibleSummary.map { OptimizationInsights(summary: $0) }
  }

  /// The page's three mutually-exclusive states. Animate on the phase so a scan
  /// that refreshes the numbers (staying `.loaded`) doesn't re-run the swap.
  private enum Phase: Equatable { case loading, loaded, empty }

  private var phase: Phase {
    if costTracker.isScanning, insights?.hasData != true { return .loading }
    if let insights, insights.hasData { return .loaded }
    return .empty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      phaseContent
        .animation(
          MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: reduceMotion),
          value: phase
        )
    }
  }

  /// The swapping page body. Each branch is `.id`-tagged and carries the shared
  /// `cardPhase` transition so a phase change is a clean replacement.
  @ViewBuilder private var phaseContent: some View {
    switch phase {
    case .loading:
      loadingCard
        .id(Phase.loading)
        .transition(MeterBarTheme.Motion.cardPhase)
    case .loaded:
      loadedContent
        .id(Phase.loaded)
        .transition(MeterBarTheme.Motion.cardPhase)
    case .empty:
      emptyStateCard
        .id(Phase.empty)
        .transition(MeterBarTheme.Motion.cardPhase)
    }
  }

  /// Wraps the populated cards in their own 14pt stack so they stay a single
  /// transition target (and keep the spacing they had as direct children).
  @ViewBuilder private var loadedContent: some View {
    if let insights, insights.hasData {
      VStack(alignment: .leading, spacing: 14) {
        content(for: insights)
      }
    }
  }

  // MARK: - Populated content

  @ViewBuilder
  private func content(for insights: OptimizationInsights) -> some View {
    scoreHero(for: insights)
    kpiGrid(for: insights)
    tokenBurnCard
    modelBreakdownCard(for: insights)
    originBreakdownCard(for: insights)
    recommendationsCard(for: insights)
  }

  private func scoreHero(for insights: OptimizationInsights) -> some View {
    DashboardStatusHero(
      title: "Optimization score \(insights.optimizationScore)/100 · \(insights.scoreGrade)",
      detail:
        "\(insights.scoreHeadline) — based on premium-model share, context size, cache reuse, "
        + "and how concentrated your usage is.",
      iconName: "leaf.fill",
      color: Self.gradeColor(insights.optimizationScore)
    )
  }

  private func kpiGrid(for insights: OptimizationInsights) -> some View {
    LazyVGrid(columns: Self.kpiColumns, alignment: .leading, spacing: 12) {
      DashboardMetricTile(
        title: "Premium model share",
        value: insights.formattedPremiumShare,
        caption: "of tokens on premium models",
        systemImage: "bolt.fill",
        indicatorTint: Self.shareTint(insights.premiumTokenShare)
      )
      DashboardMetricTile(
        title: "Cache reuse",
        value: insights.formattedCacheReuse,
        caption: "cache reads vs new context",
        systemImage: "arrow.triangle.2.circlepath",
        indicatorTint: Self.cacheTint(insights.cacheReuseRatio)
      )
      DashboardMetricTile(
        title: "Input : output",
        value: insights.formattedInputOutputRatio,
        caption: "context sent vs generated",
        systemImage: "text.append"
      )
      DashboardMetricTile(
        title: "Last 7 days",
        value: UsageFormat.tokens(insights.tokens7Day),
        caption: "\(UsageFormat.tokens(insights.tokens30Day)) over 30 days",
        systemImage: "calendar"
      )
    }
    .frame(maxWidth: .infinity)
  }

  private var tokenBurnCard: some View {
    DashboardCard(title: "Token Burn") {
      Picker("Window", selection: $chartDays) {
        Text("7 days").tag(7)
        Text("30 days").tag(30)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    } content: {
      if let summary = visibleSummary, !summary.dailyUsage.isEmpty {
        DailyUsageChart(dailyUsage: summary.dailyUsage, daysToShow: chartDays)
          .frame(height: 200)
      } else {
        Text("No daily token history yet.")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(height: 200, alignment: .center)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func modelBreakdownCard(for insights: OptimizationInsights) -> some View {
    DashboardCard(title: "Token Burn by Model") {
      if insights.topModels.isEmpty {
        Text("No per-model breakdown available in the current scan.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        VStack(spacing: 10) {
          ForEach(insights.topModels.prefix(6)) { entry in
            RankedBreakdownRow(entry: entry, showsTier: true)
          }
        }
      }
    }
  }

  private func originBreakdownCard(for insights: OptimizationInsights) -> some View {
    DashboardCard(title: "Top Usage Origins") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Where tokens are spent — agents, tool use, skills, and main chat.")
          .font(.caption)
          .foregroundColor(.secondary)

        if insights.topOrigins.isEmpty {
          Text("No origin breakdown available in the current scan.")
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          ForEach(insights.topOrigins.prefix(6)) { entry in
            RankedBreakdownRow(entry: entry, showsTier: false)
          }
        }
      }
    }
  }

  private func recommendationsCard(for insights: OptimizationInsights) -> some View {
    DashboardCard(title: "Recommendations") {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(insights.recommendations) { recommendation in
          RecommendationRow(recommendation: recommendation)
        }

        Divider()

        Label(
          "Computed locally from token totals and model names only — no prompt contents "
            + "leave your Mac.",
          systemImage: "lock.shield"
        )
        .font(.caption2)
        .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Empty / loading states

  private var emptyStateCard: some View {
    DashboardCard(title: "Optimize Your Token Usage") {
      VStack(alignment: .leading, spacing: 14) {
        Text(
          "Run a local scan to see which models and workflows burn the most tokens, "
            + "how well your cache is reused, and where you can trim spend."
        )
        .foregroundColor(.secondary)

        Label(
          "The scan reads your local Claude and Codex logs on-device. Only token totals "
            + "and model names are analyzed — never prompt contents, and nothing is uploaded.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundColor(.secondary)

        Button {
          Task { await costTracker.scanCosts(days: 30) }
        } label: {
          Label("Scan 30 Days", systemImage: "magnifyingglass")
        }
        .buttonStyle(.glassProminent)
        .disabled(costTracker.isRefreshInProgress)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var loadingCard: some View {
    DashboardCard(title: "Optimize Your Token Usage", trailing: "Scanning...") {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Scanning local token logs to build your optimization insights…")
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
  }

  // MARK: - Layout + color helpers

  private static let kpiColumns = Array(
    repeating: GridItem(.flexible(minimum: 200), spacing: 12, alignment: .top),
    count: 2
  )

  private static func gradeColor(_ score: Int) -> Color {
    switch score {
    case 70...: return MeterBarTheme.success
    case 45..<70: return MeterBarTheme.warning
    default: return MeterBarTheme.danger
    }
  }

  /// Higher premium share is redder; a low share is neutral.
  private static func shareTint(_ share: Double) -> Color {
    switch share {
    case 0.5...: return MeterBarTheme.danger
    case 0.3..<0.5: return MeterBarTheme.warning
    default: return .secondary
    }
  }

  /// Higher cache reuse is greener; low reuse is a warning.
  private static func cacheTint(_ ratio: Double?) -> Color {
    guard let ratio else { return .secondary }
    switch ratio {
    case 0.7...: return MeterBarTheme.success
    case 0.3..<0.7: return .secondary
    default: return MeterBarTheme.warning
    }
  }
}

// MARK: - Ranked breakdown row

private struct RankedBreakdownRow: View {
  let entry: RankedTokenEntry
  let showsTier: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Circle()
          .fill(MeterBarTheme.accent(for: entry.provider))
          .frame(width: 8, height: 8)

        Text(entry.name)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)

        if showsTier, entry.tier != .unknown {
          // Migrated to the shared `MeterBarChip`; fill normalizes 0.18 -> 0.14
          // and it picks up the standard hairline stroke. Tier color unchanged.
          MeterBarChip(entry.tier.label, tint: tierColor, style: .flat)
        }

        Spacer(minLength: 8)

        Text(entry.formattedTokens)
          .font(.callout)
          .monospacedDigit()
        Text(entry.formattedShare)
          .font(.caption)
          .foregroundColor(.secondary)
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
      }

      ShareBar(fraction: entry.tokenShare, tint: MeterBarTheme.accent(for: entry.provider))
    }
  }

  private var tierColor: Color {
    switch entry.tier {
    case .premium: return MeterBarTheme.danger
    case .standard: return MeterBarTheme.warning
    case .economy: return MeterBarTheme.success
    case .unknown: return .secondary
    }
  }
}

private struct ShareBar: View {
  let fraction: Double
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.quaternary)
          .frame(height: 4)
        Capsule()
          .fill(tint)
          .frame(width: max(2, proxy.size.width * clampedFraction), height: 4)
      }
    }
    .frame(height: 4)
  }

  private var clampedFraction: CGFloat {
    CGFloat(min(1, max(0, fraction)))
  }
}

// MARK: - Recommendation row

private struct RecommendationRow: View {
  let recommendation: OptimizationRecommendation

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: recommendation.systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(severityColor)
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 3) {
        Text(recommendation.title)
          .font(.callout)
          .fontWeight(.semibold)
        Text(recommendation.detail)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
  }

  private var severityColor: Color {
    switch recommendation.severity {
    case .warning: return MeterBarTheme.danger
    case .suggestion: return MeterBarTheme.warning
    case .info: return MeterBarTheme.accent(for: .claudeCode)
    case .positive: return MeterBarTheme.success
    }
  }
}
