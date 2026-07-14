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
        .buttonStyle(ProviderCardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title), \(statusText), \(snapshot.updatedText)")
        .accessibilityHint("Open \(snapshot.title) quota overview")
      } else {
        cardContent
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(snapshot.title), \(statusText), \(snapshot.updatedText)")
      }
    }
    .providerCardContextMenu(ProviderCardCommands.standard(snapshot: snapshot))
  }

  /// Chevron shown only when the card opens the limits detail, making the
  /// affordance visible instead of relying on an accessibilityHint alone.
  @ViewBuilder private var disclosureChevron: some View {
    if onSelect != nil {
      CardDisclosureChevron()
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

          disclosureChevron
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
    .contentShape(RoundedRectangle(cornerRadius: MeterBarTheme.Radius.card, style: .continuous))
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

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    // Dashboard twin of the popover's exhausted↔normal swap. This body sits
    // inside a flat DashboardTile with no per-branch glass surface, so it uses
    // a blur-replace transition + the shared smooth timing rather than a full
    // `glassEffectID` morph (which would need its own glass container to read).
    content
      .animation(
        reduceMotion ? nil : MeterBarTheme.Motion.standard,
        value: snapshot.hasExhaustedWeeklyLimit
      )
  }

  @ViewBuilder private var content: some View {
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
      .transition(.blurReplace)
    } else {
      VStack(alignment: .leading, spacing: rowSpacing) {
        ForEach(snapshot.limits) { limit in
          LimitRow(limit: limit, accentColor: snapshot.accentColor, density: .regular)
        }
      }
      .transition(.blurReplace)
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

// The dashboard/settings limit row is now `LimitRow(density: .regular)` — see
// MeterBar/Views/Components/LimitRow.swift. The bespoke `DashboardLimitRow`
// (and its popover/detail twins) was folded into that single component.
