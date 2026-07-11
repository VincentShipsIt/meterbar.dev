import SwiftUI

/// Compact Session Wake control for the menu-bar panel.
///
/// Binds to the same shared `SessionWakeSettingsStore` / `SessionWakeStatus` as
/// the Settings pane, so the watcher toggle and status chip stay in sync across
/// both surfaces (one state binding, two control surfaces).
struct SessionWakeMenuControl: View {
    @ObservedObject private var store: SessionWakeSettingsStore
    @ObservedObject private var status: SessionWakeStatus

    @MainActor
    init(store: SessionWakeSettingsStore? = nil, status: SessionWakeStatus? = nil) {
        self.store = store ?? .shared
        self.status = status ?? .shared
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Session Wake")
            } icon: {
                Image(systemName: "moon.zzz")
            }
            Spacer()
            Text(label.title)
                .font(.caption)
                .foregroundStyle(label.isAttention ? .orange : .secondary)
            Toggle("", isOn: watcherBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                // The one-time first-run confirmation happens in Settings, so
                // the menu toggle is a quick kill-switch once enabled there.
                .disabled(!store.isOn && (!store.canTurnOn || store.needsFirstRunConfirmation))
        }
    }

    private var label: SessionWakeStatusLabel {
        status.label(isOn: store.isOn)
    }

    private var watcherBinding: Binding<Bool> {
        Binding(get: { store.isOn }, set: { store.setOn($0) })
    }
}
