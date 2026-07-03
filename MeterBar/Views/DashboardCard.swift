import AppKit
import SwiftUI
import MeterBarShared

// Shared dashboard chrome extracted from UsageDashboardView.swift (R8 split). Pure move.

let overviewTileMinHeight: CGFloat = 220

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dashboardCardBackground()
    }
}

extension View {
    /// Dashboard content-card surface. Delegates to the shared `meterBarCardSurface`
    /// so the dashboard and popover cards stay visually identical.
    func dashboardCardBackground() -> some View {
        meterBarCardSurface()
    }
}
