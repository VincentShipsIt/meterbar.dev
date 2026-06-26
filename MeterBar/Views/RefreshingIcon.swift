import SwiftUI

struct RefreshingIcon: View {
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(rotationDegrees))
            .onAppear(perform: updateRotation)
            .onChange(of: isRefreshing) { _, _ in
                updateRotation()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateRotation()
            }
    }

    private func updateRotation() {
        if isRefreshing, !reduceMotion {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotationDegrees = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                rotationDegrees = 0
            }
        }
    }
}
