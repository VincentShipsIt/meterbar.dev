import Foundation

/// The AI coding assistant a Session Wake run targets.
///
/// Session Wake shipped Claude-only (#95–#99). Codex is the second provider
/// (#… this change). The `rawValue` is the stable, lowercase token used on the
/// `meterbar wake --provider` flag, in the versioned CLI JSON response, and in
/// persisted settings — never localize it.
nonisolated enum WakeProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case claude
    case codex

    /// User-facing name for menus, notifications, and status copy.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Parse a provider token (case-insensitive). Returns nil for anything not
    /// in the closed set so the CLI can fail closed with a validation error
    /// rather than silently defaulting.
    static func parse(_ raw: String) -> WakeProvider? {
        WakeProvider(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// The provider-specific behaviors the one-shot engine and the continuous
/// coordinator drive, bundled behind one seam so the orchestration stays a
/// single implementation regardless of provider.
///
/// A runtime is constructed already bound to its selected account, so callers
/// never thread a provider-typed account (`ClaudeCodeAccount` vs `CodexAccount`)
/// through the shared orchestration — they hand it a runtime and ask it to
/// discover, gate, and run.
nonisolated protocol WakeProviderRuntime: Sendable {
    /// Which provider this runtime speaks for (tags the response + candidates).
    var provider: WakeProvider { get }

    /// A short label identifying the bound account for the CLI JSON response's
    /// `account` field (a config directory or CODEX_HOME). Never a secret.
    var accountLabel: String? { get }

    /// Read-only discovery of blocked sessions for the bound account, flagging
    /// already-handled blocks via `ledger`.
    func discover(ledger: ReplayLedger) async -> [WakeSessionCandidate]

    /// A fresh, fail-closed quota decision for the bound account.
    func freshQuota() async -> WakeQuota

    /// The execution seam used to resume one session at a time.
    func makeRunner() -> WakeExecuting
}
