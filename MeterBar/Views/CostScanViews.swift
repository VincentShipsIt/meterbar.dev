import AppKit
import MeterBarShared
import SwiftUI

// Scan-progress views for the Usage page: the scope banner while a scan runs, the
// full-area shimmer for the first scan, and the badge for a refresh on top of data
// that is already showing.

/// Full-area loading treatment for the **first** scan, when there is no cost
/// data to show yet. It replaces the entire chart with an animated shimmer so
/// the empty slot reads as "working on it" rather than "nothing here." Contrast
/// with `CostScanProgressBadge`, which is a small overlay used when a scan
/// refreshes data that is *already* on screen.
struct CostScanScopeBanner: View {
  let progress: CostScanProgress

  /// A compressed-rollout gap (issue #570) is a correctness caveat, not a
  /// scale caveat, but it earns the same visual treatment `isLargeCorpus`
  /// already has: this is the one banner every scan renders, so it is the
  /// "same place" the existing partial-scan signal surfaces to the user.
  private var hasDataQualityWarning: Bool {
    progress.isLargeCorpus || progress.hasCodexCompressedRolloutGap
  }

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

      Label(progress.detailText, systemImage: hasDataQualityWarning ? "exclamationmark.triangle.fill" : "info.circle")
        .font(.caption)
        .foregroundStyle(hasDataQualityWarning ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: MeterBarTheme.Radius.medium, style: .continuous)
        .fill(hasDataQualityWarning ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05))
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
