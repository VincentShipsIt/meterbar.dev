import AppKit
import MeterBarShared
import SwiftUI

// Cost overview + breakdown cards extracted from UsageDashboardView.swift (R8 split). Pure move.

struct CostOverviewStatusCard: View {
  let summary: CostSummary?
  let isScanning: Bool
  let isRefreshingMissingDays: Bool
  let formattedTokens: String

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var subtitle: String {
    if isScanning { return "Scanning local logs" }
    if isRefreshingMissingDays { return "Updating…" }
    return "Last 30 days"
  }

  var body: some View {
    DashboardTile {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 9) {
          Image(systemName: "dollarsign.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(MeterBarTheme.success)
          VStack(alignment: .leading, spacing: 2) {
            Text("API-Rate Estimate")
              .font(.headline)
              .fontWeight(.semibold)
            Text(subtitle)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
        }

        if let formattedTotalCost = summary?.formattedTotalCost {
          Text(formattedTotalCost)
            .font(.system(size: 34, weight: .bold))
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .numericRefreshTransition(value: formattedTotalCost, reduceMotion: reduceMotion)
        } else if isScanning {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Scanning...")
              .font(.system(size: 28, weight: .bold))
              .foregroundColor(.primary)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
        } else {
          Text("Scan needed")
            .font(.system(size: 34, weight: .bold))
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }

        VStack(spacing: 7) {
          HStack {
            Text("Tokens")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text(formattedTokens)
              .font(.caption)
              .fontWeight(.semibold)
              .numericRefreshTransition(value: formattedTokens, reduceMotion: reduceMotion)
          }
          HStack {
            Text("Providers")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text("\(summary?.costs.count ?? 0)")
              .font(.caption)
              .fontWeight(.semibold)
              .numericRefreshTransition(value: summary?.costs.count ?? 0, reduceMotion: reduceMotion)
          }
          HStack {
            Text("Pricing")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Text(ModelPricing.revisionLabel)
              .font(.caption)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }
}

struct CostScanLoadingChart: View {
  let compact: Bool

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
            Text("Scanning local logs")
              .font(compact ? .caption : .subheadline)
              .fontWeight(.semibold)
            Spacer()
            Text("30 days")
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
            Text("Parsing Claude and Codex sessions")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
    }
  }
}

struct CostScanProgressBadge: View {
  let compact: Bool

  var body: some View {
    VStack {
      HStack {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(compact ? "Scanning..." : "Updating local scan")
            .font(.caption)
            .fontWeight(.semibold)
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

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var logoKind: ProviderLogoKind {
    .forService(cost.provider)
  }

  private var logoColor: Color {
    MeterBarTheme.accent(for: cost.provider)
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
          Spacer()
          Text(cost.formattedCost)
            .font(.title3)
            .bold()
            .numericRefreshTransition(value: cost.formattedCost, reduceMotion: reduceMotion)
        }

        if let quotaSnapshot, quotaSnapshot.hasExhaustedLimit {
          BlockingLimitResetCounter(
            windows: quotaSnapshot.resetWindows,
            accentColor: logoColor
          )
        }

        HStack(spacing: 14) {
          CostMetric(label: "Tokens", value: cost.formattedTokens)
          CostMetric(label: "Input", value: UsageFormat.tokens(cost.inputTokens))
          CostMetric(label: "Output", value: UsageFormat.tokens(cost.outputTokens))
          CostMetric(label: "Sessions", value: "\(cost.sessionCount)")
        }

        if !cost.modelBreakdowns.isEmpty {
          CostBreakdownSection(title: "Models", items: Array(cost.modelBreakdowns.prefix(6)))
        }

        if !cost.originBreakdowns.isEmpty {
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
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.secondary)
      Text(value)
        .font(.caption)
        .fontWeight(.semibold)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .numericRefreshTransition(value: value, reduceMotion: reduceMotion)
    }
    .frame(width: 58, alignment: .leading)
  }
}
