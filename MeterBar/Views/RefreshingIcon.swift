import SwiftUI

/// Native refresh/loading glyph for toolbar and companion controls.
struct RefreshingIcon: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .frame(width: 18, height: 18)
    }
}
