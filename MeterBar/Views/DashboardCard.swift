import AppKit
import MeterBarShared
import SwiftUI

// Shared dashboard chrome extracted from UsageDashboardView.swift (R8 split). Pure move.

let overviewTileMinHeight: CGFloat = 220

struct DashboardTile<Content: View>: View {
  let cornerRadius: CGFloat
  let padding: CGFloat
  let minHeight: CGFloat?
  let alignment: Alignment
  @ViewBuilder let content: Content

  init(
    cornerRadius: CGFloat = 6,
    padding: CGFloat = 14,
    minHeight: CGFloat? = nil,
    alignment: Alignment = .topLeading,
    @ViewBuilder content: () -> Content
  ) {
    self.cornerRadius = cornerRadius
    self.padding = padding
    self.minHeight = minHeight
    self.alignment = alignment
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
      .meterBarCardSurface(cornerRadius: cornerRadius)
  }
}

struct DashboardCard<Content: View>: View {
  let title: String
  let trailing: String?
  @ViewBuilder let content: Content

  init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    DashboardTile {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(title)
            .font(.title3)
            .bold()
          Spacer()
          if let trailing {
            Text(trailing)
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        content
      }
    }
  }
}

struct DashboardMetricTile: View {
  let title: String
  let value: String
  let caption: String
  let systemImage: String
  let tint: Color

  var body: some View {
    DashboardTile {
      VStack(alignment: .leading, spacing: 6) {
        Label(title, systemImage: systemImage)
          .font(.caption)
          .foregroundColor(.secondary)
          .labelStyle(.titleAndIcon)

        Text(value)
          .font(.title2)
          .fontWeight(.semibold)
          .foregroundStyle(tint)
          .contentTransition(.numericText())

        Text(caption)
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
