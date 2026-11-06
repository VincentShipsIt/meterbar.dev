import AppKit
import MeterBarShared
import SwiftUI

// Provider status/limit cards extracted from UsageDashboardView.swift (R8 split). Pure move.

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
