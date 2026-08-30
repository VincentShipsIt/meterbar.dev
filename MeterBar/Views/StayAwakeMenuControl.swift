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
        HStack(spacing: 8) {
            Label {
                Text("Stay Awake")
            } icon: {
                Image(systemName: manager.isAssertionHeld ? "flame.fill" : "flame")
                    .foregroundStyle(manager.isAssertionHeld ? MeterBarTheme.warning : .secondary)
            }

            Spacer()

            Text(statusText)
                .font(.caption)
                .foregroundStyle(manager.isAssertionHeld ? MeterBarTheme.warning : .secondary)
                .accessibilityHidden(true)

            Toggle("Stay Awake", isOn: Binding(
                get: { store.isEnabled },
                set: { store.setEnabled($0) }
            ))
            .labelsHidden()
            .meterBarSwitch()
            .accessibilityValue(statusText)
        }
    }

    private var statusText: String {
        if let provider = manager.activeProvider, manager.isAssertionHeld {
            return "Awake · \(provider.shortName)"
        }
        return store.isEnabled ? "Waiting for session quota" : "Off"
    }
}
