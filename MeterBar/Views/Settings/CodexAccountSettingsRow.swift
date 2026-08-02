import MeterBarShared
import SwiftUI

/// Codex multi-account row: shared layout plus a live auth-file probe.
///
/// Claude and Grok surface status from existing service state; Codex probes the
/// configured auth token asynchronously, so that lifecycle lives here rather
/// than inside the pure presentation row.
struct CodexAccountSettingsRow: View {
    init(
        account: CodexAccount,
        canDisable: Bool,
        canRemove: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onSave: @escaping (String, String?) -> Void,
        onRemove: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        connectionCheck: @escaping (CodexAccount) async -> Bool = {
            await CodexCliLocalService.shared.canAccess(account: $0)
        }
    ) {
        self.account = account
        self.canDisable = canDisable
        self.canRemove = canRemove
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onRemove = onRemove
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.connectionCheck = connectionCheck
        _connectionState = State(initialValue: account.isEnabled ? .checking : .disabled)
    }

    var body: some View {
        ProviderAccountProfileRow(
            accountName: account.name,
            isDefault: account.isDefault,
            isEnabled: account.isEnabled,
            accent: MeterBarTheme.codexAccent,
            pathLabel: "CODEX_HOME",
            pathPlaceholder: "Codex home directory",
            resolvedPath: CodexHomeDirectory.path(for: account),
            defaultPathHelp: "Defaults to ~/.codex or $CODEX_HOME; clear the field to restore that default.",
            statusPresentation: connectionState.statusPresentation,
            statusAccessibilityValue: connectionState.accessibilityValue,
            canDisable: canDisable,
            canRemove: canRemove,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            deleteMessage: "MeterBar will stop tracking this CODEX_HOME. Files and Codex login data are not deleted.",
            onEnabledChange: onEnabledChange,
            onSave: onSave,
            onRemove: onRemove,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown
        )
        .task(id: probeID) {
            await refreshConnectionState()
        }
    }

    private let account: CodexAccount
    private let canDisable: Bool
    private let canRemove: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private let onEnabledChange: (Bool) -> Void
    private let onSave: (String, String?) -> Void
    private let onRemove: () -> Void
    private let onMoveUp: () -> Void
    private let onMoveDown: () -> Void
    private let connectionCheck: (CodexAccount) async -> Bool

    @State private var connectionState: ProviderAccountConnectionState

    private var probeID: CodexConnectionProbeID {
        CodexConnectionProbeID(
            accountID: account.id,
            homeDirectory: account.homeDirectory,
            isEnabled: account.isEnabled
        )
    }

    private func refreshConnectionState() async {
        guard account.isEnabled else {
            connectionState = .disabled
            return
        }
        connectionState = .checking
        let isAuthenticated = await connectionCheck(account)
        guard !Task.isCancelled else { return }
        connectionState = isAuthenticated ? .authenticated : .loginRequired
    }
}

private struct CodexConnectionProbeID: Equatable {
    let accountID: UUID
    let homeDirectory: String?
    let isEnabled: Bool
}
