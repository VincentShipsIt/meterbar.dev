import SwiftUI

/// Compact Session Wake control for the menu-bar panel.
///
/// Binds to the same shared `SessionWakeSettingsStore` / `SessionWakeStatus` as
/// the Settings pane, so the watcher toggle and status chip stay in sync across
/// both surfaces (one state binding, two control surfaces).
struct SessionWakeMenuControl: View {
    @ObservedObject private var store: SessionWakeSettingsStore
    @ObservedObject private var status: SessionWakeStatus

    init(store: SessionWakeSettingsStore = .shared, status: SessionWakeStatus = .shared) {
        self.store = store
        self.status = status
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
                .disabled(!store.canArmWatcher || store.wakeAccountID == nil)
        }
    }

    private var label: SessionWakeStatusLabel {
        status.label(featureEnabled: store.featureEnabled)
    }

    private var watcherBinding: Binding<Bool> {
        Binding(get: { store.watcherArmed }, set: { store.setWatcherArmed($0) })
    }
}
