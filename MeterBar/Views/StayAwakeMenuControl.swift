import MeterBarShared
import SwiftUI

/// One-click Stay Awake control and always-visible held-state indicator for the
/// menu-bar popover.
struct StayAwakeMenuControl: View {
    @ObservedObject private var store: StayAwakeSettingsStore
    @ObservedObject private var manager: PowerAssertionManager

    @MainActor
    init(
        store: StayAwakeSettingsStore? = nil,
        manager: PowerAssertionManager? = nil
    ) {
        self.store = store ?? .shared
        self.manager = manager ?? .shared
    }

    var body: some View {
        Button {
            store.setEnabled(!store.isEnabled)
        } label: {
            Label("Stay Awake", systemImage: store.isEnabled ? "flame.fill" : "flame")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(manager.isAssertionHeld ? MeterBarTheme.warning : .primary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Stay Awake: \(statusText)")
        .accessibilityLabel("Stay Awake")
        .accessibilityValue(statusText)
    }

    private var statusText: String {
        if let provider = manager.activeProvider, manager.isAssertionHeld {
            return "Awake · \(provider.shortName)"
        }
        return store.isEnabled ? "Waiting for session quota" : "Off"
    }
}
