import AppKit
import MeterBarShared
import SwiftUI

// Cost overview + breakdown cards extracted from UsageDashboardView.swift (R8 split). Pure move.

struct CostOverviewStatusCard: View {
  let summary: CostSummary?
  let isScanning: Bool
  let isRefreshingMissingDays: Bool
  let formattedTokens: String
  /// The page's 7/30-day toggle. The month keeps the scan's own totals
  /// (authoritative, cache-creation tokens included); the week is cut from the
  /// cached daily rows — no rescan. Defaulted so existing hosts and tests keep
  /// meaning "the full scan window".
  var windowSelection: CostWindowSelection = .month

  @ScaledMetric(relativeTo: .title)
  private var scanningHeadlineSize: CGFloat = 28

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  /// Shared with the "30 Day Spend" card so both trailing captions say the same
  /// thing at the same time — they are driven by the same two scan flags.
  static func headerStatus(isScanning: Bool, isRefreshingMissingDays: Bool) -> String? {
    DashboardCostsSection.refreshStatusText(
      isScanning: isScanning,
      isRefreshingMissingDays: isRefreshingMissingDays
    )
  }

  /// The hero value's three mutually-exclusive states. Animate the swap on the
  /// *phase*, not `formattedTotalCost` — a refreshed dollar figure re-renders
  /// the same `.loaded` phase and updates in place via `.numericText()`.
  private enum Phase: Equatable { case loaded, scanning, needsScan }

  private var phase: Phase {
    if summary?.formattedTotalCost != nil { return .loaded }
    if isScanning { return .scanning }
    return .needsScan
  }

  /// The figures the card renders for the selected window. The month view keeps
  /// the scan's own totals; the week view aggregates the cached daily rows,
  /// which carry input/output/cache-read tokens but not cache-creation tokens —
  /// the same basis every daily chart on this page already reports.
  private var figures: (cost: String, tokens: String, providers: Int) {
    guard let summary else { return ("", formattedTokens, 0) }
    guard windowSelection != .month else {
      return (summary.formattedTotalCost, formattedTokens, summary.costs.count)
    }
    let window = windowSelection.costWindow(from: summary)
    return (
      UsageFormat.cost(window.totalCostUSD),
      UsageFormat.tokens(window.totalTokens),
      window.providers.count
    )
  }

  /// Verification dates of the rate entries this scan actually priced with, not
  /// a global table revision (issue #339). Summaries cached before dated
  /// pricing carry none, so those fall back to the shipped table's own dates.
  private var pricingProvenance: PricingProvenance {
    summary?.pricing.flatMap { $0.isEmpty ? nil : $0 } ?? ModelPricing.tableProvenance
  }

  var body: some View {
    DashboardTile(minHeight: CostHeadlineCardMetrics.minimumHeight) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: "dollarsign.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(MeterBarTheme.success)
          VStack(alignment: .leading, spacing: 2) {
            Text("API-Rate Estimate")
              .font(.headline)
              .fontWeight(.semibold)
            Text(windowSelection.subtitle)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          DashboardCardCaption(
            text: Self.headerStatus(
              isScanning: isScanning,
              isRefreshingMissingDays: isRefreshingMissingDays
            )
          )
        }

        heroValue
          .animation(
            MeterBarTheme.Motion.resolve(MeterBarTheme.Motion.standard, reduceMotion: reduceMotion),
            value: phase
          )

        VStack(spacing: 7) {
          HStack {
            Text("Tokens")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text(figures.tokens)
              .font(.caption)
              .fontWeight(.semibold)
              .numericRefreshTransition(value: figures.tokens, reduceMotion: reduceMotion)
          }
          HStack {
            Text("Providers")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text("\(figures.providers)")
              .font(.caption)
              .fontWeight(.semibold)
              .numericRefreshTransition(value: figures.providers, reduceMotion: reduceMotion)
          }
          HStack {
            Text("Pricing")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text(pricingProvenance.label)
              .font(.caption)
              .fontWeight(.semibold)
              .help(pricingProvenance.diagnosticNote ?? pricingProvenance.label)
          }
        }
      }
    }
  }

  /// The swapping hero figure. Each branch is `.id`-tagged and carries the
  /// shared `cardPhase` transition so a phase change is a clean replacement.
  @ViewBuilder private var heroValue: some View {
    switch phase {
    case .loaded:
      CostHeadlineAmount(figures.cost)
        .id(Phase.loaded)
        .transition(MeterBarTheme.Motion.cardPhase)
    case .scanning:
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Scanning...")
          .font(.system(size: scanningHeadlineSize, weight: .bold))
          .foregroundColor(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .id(Phase.scanning)
      .transition(MeterBarTheme.Motion.cardPhase)
    case .needsScan:
      Text("Scan needed")
        .font(.largeTitle)
        .fontWeight(.bold)
        .foregroundColor(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .id(Phase.needsScan)
        .transition(MeterBarTheme.Motion.cardPhase)
    }
  }
}

private enum CostHeadlineCardMetrics {
  static let minimumHeight: CGFloat = 180
}

/// One typography contract for the headline cost amount.
private struct CostHeadlineAmount: View {
  let value: String

  init(_ value: String) {
    self.value = value
  }

  var body: some View {
    Text(value)
      .font(.largeTitle)
      .fontWeight(.bold)
      .monospacedDigit()
      .foregroundStyle(.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .contentTransition(.numericText())
  }
}

/// Full-area loading treatment for the **first** scan, when there is no cost
/// data to show yet. It replaces the entire chart with an animated shimmer so
/// the empty slot reads as "working on it" rather than "nothing here." Contrast
/// with `CostScanProgressBadge`, which is a small overlay used when a scan
/// refreshes data that is *already* on screen.
struct CostScanScopeBanner: View {
  let progress: CostScanProgress

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(progress.statusText)
          .font(.subheadline)
          .fontWeight(.semibold)
          .lineLimit(2)
        Spacer(minLength: 8)
        Text("Last \(progress.windowDays) days")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let fraction = progress.fraction {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
      }

      Label(progress.detailText, systemImage: progress.isLargeCorpus ? "exclamationmark.triangle.fill" : "info.circle")
        .font(.caption)
        .foregroundStyle(progress.isLargeCorpus ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: MeterBarTheme.Radius.medium, style: .continuous)
        .fill(progress.isLargeCorpus ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05))
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(progress.statusText)
    .accessibilityValue(progress.detailText)
  }
}

struct CostScanLoadingChart: View {
  let compact: Bool
  var progress: CostScanProgress?

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private let barCount = 30

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      GeometryReader { proxy in
        let spacing: CGFloat = compact ? 4 : 5
        let labelHeight: CGFloat = compact ? 34 : 44
        let chartHeight = max(42, proxy.size.height - labelHeight)
        let barWidth = max(
          4, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
        let time = timeline.date.timeIntervalSinceReferenceDate
        let sweepWidth = max(42, proxy.size.width * 0.18)
        let sweepProgress = CGFloat(time.truncatingRemainder(dividingBy: 1.8) / 1.8)
        let sweepX = sweepProgress * (proxy.size.width + sweepWidth) - sweepWidth

        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text(progress?.statusText ?? "Scanning local logs")
              .font(compact ? .caption : .subheadline)
              .fontWeight(.semibold)
              .lineLimit(2)
            Spacer()
            Text(progress.map { "\($0.windowDays) days" } ?? "30 days")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          ZStack(alignment: .leading) {
            HStack(alignment: .bottom, spacing: spacing) {
              ForEach(0..<barCount, id: \.self) { index in
                let seed = Double(((index * 17) % 11) + 2) / 13
                let wave = reduceMotion ? 0.5 : (sin((time * 3.2) + Double(index) * 0.55) + 1) / 2
                let height = chartHeight * CGFloat(0.14 + (seed * 0.44) + (wave * 0.28))

                RoundedRectangle(cornerRadius: MeterBarTheme.Radius.small)
                  .fill(
                    LinearGradient(
                      colors: [
                        MeterBarTheme.codexAccent.opacity(0.18 + wave * 0.16),
                        MeterBarTheme.cursorAccent.opacity(0.16 + seed * 0.20),
                      ],
                      startPoint: .bottom,
                      endPoint: .top
                    )
                  )
                  .frame(width: barWidth, height: max(4, height))
              }
            }
            .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottomLeading)

            if !reduceMotion {
              Rectangle()
                .fill(
                  LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.22), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                )
                .frame(width: sweepWidth, height: chartHeight)
                .offset(x: sweepX)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.medium))

          if !compact {
            Text(progress?.detailText ?? "Parsing session files from the last 30 days")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
    }
  }
}

/// Small overlay badge shown when a scan runs **on top of** data that is
/// already displayed — the chart stays visible (dimmed) and this badge signals
/// the in-progress refresh in a corner. Contrast with `CostScanLoadingChart`,
/// which takes over the whole area when there is nothing to show yet.
struct CostScanProgressBadge: View {
  let compact: Bool
  var progress: CostScanProgress?

  var body: some View {
    VStack {
      HStack {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(progress?.statusText ?? (compact ? "Scanning..." : "Updating local scan"))
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(2)
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 6 : 8)
        .glassEffect(.regular, in: .capsule)

        Spacer()
      }

      Spacer()
    }
    .padding(compact ? 8 : 10)
  }
}

struct ProviderCostBreakdown: View {
  let cost: TokenCost
  var quotaSnapshot: ProviderSnapshot?
  /// Windowed totals for this provider when the page's 7-day window is active.
  /// `nil` renders the scan-period card exactly as before. Daily rows carry no
  /// session counts or origin split, so the windowed card reports cache-read
  /// tokens and the project rollup in their place.
  var window: ProviderDailyTotal?
  /// Caption naming the window the figures cover, shown only when windowed.
  var windowSubtitle: String?
  /// Installations whose daily records contributed to this aggregate card.
  var contributingDeviceNames: [String] = []

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var logoKind: ProviderLogoKind {
    .forService(cost.provider)
  }

  private var logoColor: Color {
    MeterBarTheme.accent(for: cost.provider)
  }

  private var formattedCost: String {
    window?.formattedCost ?? cost.formattedCost
  }

  private var modelBreakdowns: [TokenUsageBreakdown] {
    window.map { $0.modelBreakdowns ?? [] } ?? cost.modelBreakdowns
  }

  var body: some View {
    DashboardTile {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          ProviderTitle(
            title: cost.provider.displayName,
            logoKind: logoKind,
            color: logoColor,
            font: .headline
          )
          if let windowSubtitle {
            DashboardCardCaption(text: windowSubtitle)
          }
          if !contributingDeviceNames.isEmpty {
            DashboardCardCaption(text: contributingDeviceNames.joined(separator: ", "))
              .help("Contributing Macs")
          }
          Spacer()
          Text(formattedCost)
            .font(.title3)
            .bold()
            .numericRefreshTransition(value: formattedCost, reduceMotion: reduceMotion)
        }

        if let quotaSnapshot, quotaSnapshot.hasExhaustedLimit {
          BlockingLimitResetCounter(
            windows: quotaSnapshot.resetWindows,
            accentColor: logoColor
          )
        }

        if let window {
          HStack(spacing: 14) {
            CostMetric(label: "Tokens", value: UsageFormat.groupedTokens(window.totalTokens))
            CostMetric(label: "Input", value: UsageFormat.tokens(window.inputTokens))
            CostMetric(label: "Output", value: UsageFormat.tokens(window.outputTokens))
            CostMetric(label: "Cache", value: UsageFormat.tokens(window.cacheReadTokens))
          }
        } else {
          HStack(spacing: 14) {
            CostMetric(label: "Tokens", value: cost.formattedTokens)
            CostMetric(label: "Input", value: UsageFormat.tokens(cost.inputTokens))
            CostMetric(label: "Output", value: UsageFormat.tokens(cost.outputTokens))
            CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
          }
        }

        if !modelBreakdowns.isEmpty {
          CostBreakdownSection(title: "Models", items: Array(modelBreakdowns.prefix(6)))
        }

        if let window {
          if let projects = window.projectBreakdowns, !projects.isEmpty {
            CostBreakdownSection(title: "Projects", items: Array(projects.prefix(6)))
          }
        } else if !cost.originBreakdowns.isEmpty {
          CostBreakdownSection(title: "Usage Origin", items: Array(cost.originBreakdowns.prefix(6)))
        }
      }
    }
  }
}

struct CostBreakdownSection: View {
  let title: String
  let items: [TokenUsageBreakdown]

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      ForEach(items) { item in
        HStack(spacing: 10) {
          Text(item.name)
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .frame(width: 150, alignment: .leading)

          UsageDetailMetric(label: "Tokens", value: UsageFormat.tokens(item.totalTokens))
          UsageDetailMetric(label: "Input", value: UsageFormat.tokens(item.inputTokens))
          UsageDetailMetric(label: "Output", value: UsageFormat.tokens(item.outputTokens))
          UsageDetailMetric(label: "Cache", value: UsageFormat.tokens(item.cacheReadTokens))

          Spacer()

          Text(item.formattedCost)
            .font(.caption)
            .fontWeight(.semibold)
        }
        .padding(.vertical, MeterBarTheme.Spacing.xxs)
      }
    }
    .padding(.top, MeterBarTheme.Spacing.xs)
  }
}

struct CostMetric: View {
  let label: String
  let value: String

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(value)
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .numericRefreshTransition(value: value, reduceMotion: reduceMotion)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityValue(value)
  }
}

struct UsageDetailMetric: View {
  let label: String
  let value: String

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundColor(.secondary)
      Text(value)
        .font(.caption)
        .fontWeight(.semibold)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .numericRefreshTransition(value: value, reduceMotion: reduceMotion)
    }
    .frame(width: 58, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityValue(value)
  }
}
