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
                .accessibilityHidden(true)
            // Real label kept but hidden visually so VoiceOver announces
            // "Session Wake, <on/off>" instead of an unnamed switch; the status
            // text above is folded in as the accessibility value.
            Toggle("Session Wake", isOn: watcherBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityValue(label.title)
                // The one-time first-run confirmation happens in Settings, so
                // the menu toggle is a quick kill-switch once enabled there.
                .disabled(!store.isOn && (!store.canTurnOn || store.needsFirstRunConfirmation))
        }
    }

    /// Whether the compact control belongs in the menu-bar popover right now.
    ///
    /// Shown when the watcher is on — so the stop-the-watcher kill switch is
    /// always one click away — or when it is ready to be armed (a wake account is
    /// configured). Hidden when unconfigured, so users who never touch Session
    /// Wake (e.g. Codex-only) don't see an inert row.
    static func shouldShow(featureEnabled: Bool, isOn: Bool, canTurnOn: Bool) -> Bool {
        featureEnabled && (isOn || canTurnOn)
    }

    private var label: SessionWakeStatusLabel {
        status.label(isOn: store.isOn)
    }

    private var watcherBinding: Binding<Bool> {
        Binding(get: { store.isOn }, set: { store.setOn($0) })
    }
}
