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
  /// Every enabled provider/account, *unfiltered* — the recommendation card
  /// needs the ones without cached usage so it can list them as "no data"
  /// instead of quietly dropping them.
  let providerSnapshots: [ProviderSnapshot]

  /// Explicit initializer: the private `@StateObject` storage would lower the
  /// synthesized memberwise initializer to file-private, so this keeps the page
  /// constructible from `UsageDashboardView` (and from the test target).
  init(providerSnapshots: [ProviderSnapshot] = []) {
    self.providerSnapshots = providerSnapshots
  }

  @StateObject private var costTracker = CostTracker.shared
  @StateObject private var providerVisibility = ProviderVisibilityStore.shared

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  /// The same persisted 7/30-day window the Costs page uses — one preference,
  /// two pages. Replaces the picker that used to hide inside the Token Burn
  /// card and the fixed "Last 7 days" tile beside it.
  @AppStorage(StorageKeys.costsWindowDays)
  private var costsWindowDays = CostWindowSelection.month.rawValue

  private var windowSelection: CostWindowSelection {
    CostWindowSelection(rawValue: costsWindowDays) ?? .month
  }

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
      windowPicker
      recommendationCard
      phaseContent
        .animation(
          MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: reduceMotion),
          value: phase
        )
    }
  }

  /// The page-level window control, in the same position and style as the
  /// Costs page's — the two pages share the persisted selection.
  private var windowPicker: some View {
    HStack {
      Spacer()
      Picker("Reporting window", selection: $costsWindowDays) {
        ForEach(CostWindowSelection.allCases) { window in
          Text(window.pickerLabel).tag(window.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel("Reporting window")
    }
  }

  // MARK: - What to use next

  /// The ranked "what should I use next?" card.
  ///
  /// Sits outside the page's loading/loaded/empty phase on purpose: it reads the
  /// quota snapshots the app already refreshes, so it answers the question
  /// before a single token log has been scanned — and keeps answering it while a
  /// scan runs. Ticks on the shared reset-countdown schedule so the countdowns,
  /// and the ranking that weighs them, stay current without a clock of its own.
  @ViewBuilder private var recommendationCard: some View {
    TimelineView(.periodic(from: ResetCountdownSchedule.anchor, by: ResetCountdownSchedule.interval)) { timeline in
      let recommendation = providerSnapshots.headroomRecommendation(now: timeline.date)
      if !recommendation.rows.isEmpty || !recommendation.unavailable.isEmpty {
        DashboardCard(title: "What To Use Next", trailing: Self.recommendationCaption(for: recommendation)) {
          VStack(alignment: .leading, spacing: 12) {
            if let headline = recommendation.headline {
              Text(headline)
                .font(.callout)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(recommendation.rows.enumerated()), id: \.element.id) { index, row in
              HeadroomRecommendationRow(rank: index + 1, row: row)
            }

            if !recommendation.unavailable.isEmpty {
              Divider()
              // Named, not hidden: a provider MeterBar cannot read is a fact the
              // user needs, and guessing a rank for it would be worse than
              // saying nothing.
              Text("No data")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
              ForEach(recommendation.unavailable) { entry in
                HeadroomUnavailableRow(entry: entry)
              }
            }

            Divider()

            Label(
              "Ranked on your Mac from quota data MeterBar already caches — no extra requests, "
                + "and nothing switches tools for you.",
              systemImage: "lock.shield"
            )
            .font(.caption2)
            .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  /// Card caption. Names the state instead of restating the headline.
  ///
  /// Internal (not private) so the wording can be asserted without hosting the
  /// page, matching `recentWindowTile(tokens7Day:tokens30Day:)`.
  static func recommendationCaption(for recommendation: ProviderRecommendation) -> String {
    if recommendation.isEmpty { return "No usable data" }
    if recommendation.isFullyExhausted { return "Every window spent" }
    return "Ranked by remaining headroom"
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

  /// Copy for the "Last 7 days" tile.
  ///
  /// A quiet week formatted straight through renders as a bare `0` sitting next
  /// to a caption boasting billions over 30 days, which reads as a broken
  /// counter rather than as no usage. An empty window says so in words instead,
  /// and only quotes the 30-day total when that total is the thing making the
  /// empty week legible.
  ///
  /// Internal (not private) so the wording can be asserted without hosting the
  /// page, matching `DashboardStatusSection.refreshButtonTitle(isRefreshing:)`.
  static func recentWindowTile(tokens7Day: Int, tokens30Day: Int) -> (value: String, caption: String) {
    guard tokens7Day > 0 else {
      guard tokens30Day > 0 else {
        return (value: "None", caption: "no tokens recorded in the last 30 days")
      }
      return (value: "None", caption: "nothing this week — \(UsageFormat.tokens(tokens30Day)) over 30 days")
    }
    return (
      value: UsageFormat.tokens(tokens7Day),
      caption: "\(UsageFormat.tokens(tokens30Day)) over 30 days"
    )
  }

  /// The window KPI tile, following the page's 7/30-day toggle. The week keeps
  /// `recentWindowTile`'s empty-week wording; the month reports the 30-day
  /// total the rest of the page's insights are computed over.
  static func windowTile(
    selection: CostWindowSelection,
    tokens7Day: Int,
    tokens30Day: Int
  ) -> (title: String, value: String, caption: String) {
    switch selection {
    case .week:
      let tile = recentWindowTile(tokens7Day: tokens7Day, tokens30Day: tokens30Day)
      return (selection.subtitle, tile.value, tile.caption)
    case .month:
      guard tokens30Day > 0 else {
        return (selection.subtitle, "None", "no tokens recorded in the last 30 days")
      }
      return (selection.subtitle, UsageFormat.tokens(tokens30Day), "tokens in the last 30 days")
    case .monthToDate:
      guard tokens30Day > 0 else {
        return (selection.subtitle, "None", "no tokens recorded this month")
      }
      return (selection.subtitle, UsageFormat.tokens(tokens30Day), "tokens in the cached month-to-date window")
    }
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
      let recentWindow = Self.windowTile(
        selection: windowSelection,
        tokens7Day: insights.tokens7Day,
        tokens30Day: insights.tokens30Day
      )
      DashboardMetricTile(
        title: recentWindow.title,
        value: recentWindow.value,
        caption: recentWindow.caption,
        systemImage: "calendar"
      )
    }
    .frame(maxWidth: .infinity)
  }

  private var tokenBurnCard: some View {
    // No in-card picker: the page-level window toggle above governs this chart
    // (and the window tile), matching the Costs page's pattern.
    DashboardCard(title: "Token Burn", trailing: windowSelection.subtitle) {
      if let summary = visibleSummary, !summary.dailyUsage.isEmpty {
        DailyUsageChart(dailyUsage: summary.dailyUsage, daysToShow: max(1, windowSelection.dayCount()))
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

  /// One row of four. The tiles are headline numbers meant to be read at a
  /// glance; a 2×2 block doubled the band's height and pushed the token-burn
  /// chart below the fold. The minimum drops accordingly — four tiles have to
  /// fit the same width two used to.
  ///
  /// Internal (not private) so the single-row requirement can be pinned by a
  /// test rather than re-litigated the next time a tile is added.
  static let kpiColumns = Array(
    repeating: GridItem(.flexible(minimum: 96), spacing: 12, alignment: .top),
    count: 4
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

// MARK: - Headroom recommendation rows

/// One row of the "what to use next" ranking.
///
/// Every value on the row is an input to its score — binding window, percent
/// left, reset countdown, pace — so the ordering can be read off the row rather
/// than taken on faith. Deliberately plain: this is arithmetic over cached
/// quota numbers, not a prediction.
struct HeadroomRecommendationRow: View {
  struct Content: Equatable {
    let statusBand: QuotaBand
    let valueText: String
    let detailParts: [String]

    init(row: ProviderRecommendationRow) {
      statusBand = row.band
      valueText = row.headroomText
      if row.isExhausted {
        detailParts = [row.windowTitle, row.availabilityText].compactMap { $0 }
      } else {
        detailParts = [row.windowTitle, row.resetText, row.paceText].compactMap { $0 }
      }
    }
  }

  let rank: Int
  let row: ProviderRecommendationRow

  var content: Content { Content(row: row) }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text("\(rank)")
          .font(.caption)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundColor(.secondary)
          .frame(width: 14, alignment: .trailing)

        Circle()
          .fill(MeterBarTheme.accent(for: row.service))
          .frame(width: 8, height: 8)

        Text(row.name)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)

        ProviderCardStatusLabel(band: content.statusBand)

        Spacer(minLength: 8)

        Text(content.valueText)
          .font(.callout)
          .monospacedDigit()
      }

      ShareBar(
        fraction: Double(row.percentLeft) / 100,
        tint: MeterBarTheme.accent(for: row.service)
      )

      if !content.detailParts.isEmpty {
        Text(content.detailParts.joined(separator: " · "))
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Rank \(rank)")
    .accessibilityValue(row.summary)
  }
}

/// A provider left out of the ranking, with the reason in place of a rank.
private struct HeadroomUnavailableRow: View {
  let entry: ProviderRecommendationUnavailableRow

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(MeterBarTheme.accent(for: entry.service))
        .frame(width: 8, height: 8)

      Text(entry.name)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 8)

      Text(entry.detail)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(entry.name)
    .accessibilityValue(entry.detail)
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
