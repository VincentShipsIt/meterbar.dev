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
    cornerRadius: CGFloat = 12,
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

struct DashboardCard<Content: View, Trailing: View>: View {
  let title: String
  let trailing: Trailing
  @ViewBuilder let content: Content

  init(
    title: String,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.trailing = trailing()
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
          trailing
        }
        content
      }
    }
  }
}

extension DashboardCard where Trailing == DashboardCardCaption {
  init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title: title) {
      DashboardCardCaption(text: trailing)
    } content: {
      content()
    }
  }
}

struct DashboardCardCaption: View {
  let text: String?

  var body: some View {
    if let text {
      Text(text)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
}

struct DashboardMetricTile: View {
  enum Style {
    case regular
    case compact

    var minHeight: CGFloat? {
      switch self {
      case .regular:
        return nil
      case .compact:
        return 104
      }
    }

    var spacing: CGFloat {
      switch self {
      case .regular:
        return 6
      case .compact:
        return 10
      }
    }

    var titleFont: Font {
      .caption
    }

    var titleWeight: Font.Weight? {
      switch self {
      case .regular:
        return nil
      case .compact:
        return .semibold
      }
    }

    var valueFont: Font {
      switch self {
      case .regular:
        return .title2
      case .compact:
        return .title3
      }
    }

    var captionFont: Font {
      switch self {
      case .regular:
        return .caption2
      case .compact:
        return .caption
      }
    }

    var valueMinimumScaleFactor: CGFloat {
      switch self {
      case .regular:
        return 1
      case .compact:
        return 0.72
      }
    }

    var captionMinimumScaleFactor: CGFloat {
      switch self {
      case .regular:
        return 1
      case .compact:
        return 0.8
      }
    }
  }

  let title: String
  let value: String
  let caption: String
  let systemImage: String
  let tint: Color
  var style: Style = .regular

  var body: some View {
    DashboardTile(minHeight: style.minHeight) {
      VStack(alignment: .leading, spacing: style.spacing) {
        Label(title, systemImage: systemImage)
          .font(style.titleFont)
          .fontWeight(style.titleWeight)
          .foregroundColor(.secondary)
          .labelStyle(.titleAndIcon)
          .lineLimit(1)

        Text(value)
          .font(style.valueFont)
          .fontWeight(.semibold)
          .foregroundStyle(tint)
          .lineLimit(1)
          .minimumScaleFactor(style.valueMinimumScaleFactor)
          .contentTransition(.numericText())

        Text(caption)
          .font(style.captionFont)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(style.captionMinimumScaleFactor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
