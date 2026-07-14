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
