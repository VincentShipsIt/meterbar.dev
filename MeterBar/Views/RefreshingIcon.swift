import SwiftUI

/// Native refresh/loading glyph for toolbar and companion controls.
struct RefreshingIcon: View {
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .transition(.opacity)
            } else {
                Image(systemName: "arrow.clockwise")
                    .transition(.opacity)
            }
        }
        .frame(width: 18, height: 18)
        // `.symbolEffect(.replace)` can't span the Image → ProgressView type
        // change, so crossfade the two glyphs instead. Instant under Reduce
        // Motion (animation resolves to nil).
        .animation(MeterBarTheme.Motion.snappy(reduceMotion: reduceMotion), value: isRefreshing)
    }
}
