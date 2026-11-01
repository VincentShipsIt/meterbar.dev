import SwiftUI

/// IDs for popover cards that are not provider snapshots.
enum PopoverCardID {
    static let providerErrors = "popover-provider-errors"
    static let providerStatus = "popover-provider-status"
    /// Stay Awake, Session Wake and the footer: hover sources that own no detail
    /// panel. Entering one takes hover ownership away from the open panel, so
    /// the panel closes instead of waiting on the popover-wide "still inside".
    /// Each has its own ID so a late exit from one cannot clear the next one's
    /// ownership.
    static let stayAwake = "popover-control-stay-awake"
    static let sessionWake = "popover-control-session-wake"
    static let footer = "popover-control-footer"
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
