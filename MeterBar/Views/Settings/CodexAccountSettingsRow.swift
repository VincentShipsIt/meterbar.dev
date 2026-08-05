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
        connectionCheck: (@Sendable () async -> Bool)? = nil
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
        // Bind the account into the probe closure's heap context *here*, in the
        // initializer, where it is provably live — rather than passing it as an
        // argument to a stored async closure later.
        //
        // A stored `(CodexAccount) async -> Bool` is an abstract function type,
        // so every parameter is passed indirectly (`@in_guaranteed`) through a
        // reabstraction thunk: the callee receives an *address it does not own*.
        // Reached from `.task`, the buffer behind that address was already dead
        // by the time `canAccess` copied out of it, and the outlined copy
        // retained a garbage `String` field — `EXC_BAD_ACCESS` in `swift_retain`
        // at `0x8`. That is the crash in 1.8.3, 1.8.31 and 1.8.32; all three
        // fixes reordered work *around* the thunk instead of removing it.
        //
        // A `() async -> Bool` seam has no parameter to reabstract. The account
        // lives in this closure's heap context for the closure's whole lifetime
        // and `canAccess` becomes a direct call. The thunk is not reordered —
        // it cannot be emitted at all.
        //
        // Acceptance criterion, mechanical and checkable against the shipped
        // Release binary (not against this reasoning — reasoning is what failed
        // three times): no reabstraction thunk taking `@in_guaranteed
        // CodexAccount` may exist in the binary.
        if let connectionCheck {
            self.probeConnection = connectionCheck
        } else {
            self.probeConnection = { await CodexCliLocalService.shared.canAccess(account: account) }
        }
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
    /// Takes no argument by design — see the note in `init`.
    private let probeConnection: @Sendable () async -> Bool

    @State private var connectionState: ProviderAccountConnectionState

    private var probeID: CodexConnectionProbeID {
        CodexConnectionProbeID(
            accountID: account.id,
            homeDirectory: account.homeDirectory,
            isEnabled: account.isEnabled
        )
    }

    private func refreshConnectionState() async {
        // No account crosses this call: `probeConnection` already holds it.
        guard account.isEnabled else {
            connectionState = .disabled
            return
        }
        connectionState = .checking
        let isAuthenticated = await probeConnection()
        guard !Task.isCancelled else { return }
        connectionState = isAuthenticated ? .authenticated : .loginRequired
    }
}

private struct CodexConnectionProbeID: Equatable {
    let accountID: UUID
    let homeDirectory: String?
    let isEnabled: Bool
}
