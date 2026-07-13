import AppKit
import MeterBarShared
import SwiftUI

// Provider status/limit cards extracted from UsageDashboardView.swift (R8 split). Pure move.

struct DashboardStatusHero: View {
  let title: String
  let detail: String
  let iconName: String
  let color: Color

  var body: some View {
    DashboardTile {
      HStack(alignment: .center, spacing: 14) {
        ZStack {
          Circle()
            .fill(.quaternary)
            .frame(width: 46, height: 46)
          Image(systemName: iconName)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(color)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.title3)
            .fontWeight(.semibold)
          Text(detail)
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        Spacer()
      }
    }
  }
}

struct ProviderOverviewStatusCard: View {
  let snapshot: ProviderSnapshot
  var onSelect: (() -> Void)?

  private var statusText: String {
    snapshot.band?.shortLabel ?? "No data"
  }

  private var statusColor: Color {
    snapshot.band?.color ?? .secondary
  }

  var body: some View {
    Group {
      if let onSelect {
        Button(action: onSelect) {
          cardContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title), \(statusText), \(snapshot.updatedText)")
        .accessibilityHint("Open \(snapshot.title) quota overview")
      } else {
        cardContent
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(snapshot.title), \(statusText), \(snapshot.updatedText)")
      }
    }
  }

  private var cardContent: some View {
    DashboardTile(minHeight: overviewTileMinHeight) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 9) {
          ProviderLogoView(kind: snapshot.logoKind, size: 20, foregroundColor: snapshot.accentColor)
          VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title)
              .font(.headline)
              .fontWeight(.semibold)
            Text(snapshot.updatedText)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Text(statusText)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(statusColor)
        }

        ProviderLimitsBody(snapshot: snapshot, emptyMinHeight: 54, rowSpacing: 12)

        // Reset-credits + extra-usage badges, matching the popover card
        // (shared component so the two surfaces can't drift — issue #40).
        let badges = ProviderStatusBadges(snapshot: snapshot, style: .regular)
        if badges.hasContent {
          badges
        }
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

struct ProviderLimitsCard: View {
  let snapshot: ProviderSnapshot

  var body: some View {
    DashboardTile {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          ProviderTitle(
            title: snapshot.title,
            logoKind: snapshot.logoKind,
            color: snapshot.accentColor,
            font: .title3
          )
          Spacer()
          Text(snapshot.updatedText)
            .font(.caption)
            .foregroundColor(.secondary)
        }

        ProviderLimitsBody(snapshot: snapshot, emptyFont: .subheadline, rowSpacing: 12)

        // Same reset-credits + extra-usage badges as the popover card.
        let badges = ProviderStatusBadges(snapshot: snapshot, style: .regular)
        if badges.hasContent {
          badges
        }
      }
    }
  }
}

private struct ProviderLimitsBody: View {
  let snapshot: ProviderSnapshot
  var emptyFont: Font = .caption
  var emptyMinHeight: CGFloat?
  var rowSpacing: CGFloat = 12

  var body: some View {
    if snapshot.limits.isEmpty {
      Text("No quota windows reported")
        .font(emptyFont)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: emptyMinHeight, alignment: .topLeading)
    } else if snapshot.hasExhaustedWeeklyLimit {
      BlockingLimitResetCounter(
        windows: snapshot.resetWindows,
        accentColor: snapshot.accentColor
      )
    } else {
      VStack(alignment: .leading, spacing: rowSpacing) {
        ForEach(snapshot.limits) { limit in
          DashboardLimitRow(limit: limit, accentColor: snapshot.accentColor)
        }
      }
    }
  }
}

struct ProviderTitle: View {
  let title: String
  let logoKind: ProviderLogoKind
  let color: Color
  let font: Font

  var body: some View {
    HStack(spacing: 8) {
      ProviderLogoView(kind: logoKind, size: 18, foregroundColor: color)
      Text(title)
        .font(font)
        .fontWeight(.semibold)
    }
  }
}

struct DashboardLimitRow: View {
  let limit: SnapshotLimit
  let accentColor: Color

  private var isOut: Bool {
    limit.percentLeft <= 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(limit.title)
          .font(.subheadline)
          .bold()
        if limit.usageLimit.isEstimated {
          Text("Estimated")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
        }
        Spacer()
        Text(trailingValue)
          .font(.subheadline)
          .bold()
          .foregroundColor(isOut ? MeterBarTheme.danger : .primary)
      }

      UsageBar(
        usedPercentage: limit.usedPercent,
        accentColor: accentColor,
        pace: limit.usageLimit.isEstimated ? nil : limit.usageLimit.pace(),
        paceContext: limit.paceContext
      )

      HStack {
        Text(usedValue)
          .font(.caption)
          .foregroundColor(.secondary)
        if !limit.usageLimit.isEstimated, let pace = limit.usageLimit.pace() {
          Text(pace.leftLabel)
            .font(.caption)
            .foregroundColor(paceLabelColor(pace))
        }
        Spacer()
        if limit.usageLimit.resetTime != nil {
          ResetCountdownLabel(
            title: nil,
            limit: limit.usageLimit,
            font: .caption,
            foregroundColor: .secondary,
            iconSize: 10
          )
        }
      }
    }
  }

  private var trailingValue: String {
    if limit.valueStyle == .currency {
      return "\(UsageFormat.cost(max(0, limit.usageLimit.total - limit.usageLimit.used))) left"
    }
    return (isOut && !limit.usageLimit.isEstimated) ? "Out" : limit.usageLimit.percentLeftText
  }

  private var usedValue: String {
    if limit.valueStyle == .currency {
      return "\(UsageFormat.cost(limit.usageLimit.used)) spent"
    }
    return limit.usageLimit.usedPercentageText
  }

  private func paceLabelColor(_ pace: UsagePace) -> Color {
    if pace.isExhausted {
      return MeterBarTheme.danger
    }
    switch pace.stage {
    case .reserve:
      return MeterBarTheme.success
    case .deficit:
      return MeterBarTheme.warning
    case .onPace:
      return .secondary
    }
  }
}
