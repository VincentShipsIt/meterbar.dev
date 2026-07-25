import SwiftUI

/// IDs for popover cards that are not provider snapshots.
enum PopoverCardID {
    static let providerStatus = "popover-provider-status"
}

/// Live frames (SwiftUI global space) of the popover cards, keyed by card ID,
/// so the secondary detail panel can top-align with the clicked card.
struct PopoverCardFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func reportPopoverCardFrame(id: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PopoverCardFramesPreferenceKey.self,
                    value: [id: proxy.frame(in: .global)]
                )
            }
        )
    }
}
