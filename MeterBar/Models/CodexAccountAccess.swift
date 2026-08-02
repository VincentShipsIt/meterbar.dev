import Foundation

/// Per-account Codex auth truth, keyed by account id.
///
/// Codex carried a single `hasAccess` flag probed from the default sentinel, so
/// every custom `CODEX_HOME` profile presented as logged out no matter what its
/// own `auth.json` said, and a probe of one profile could publish over another's
/// state. Every consumer of Codex connection state — the Providers page status
/// row, the settings sidebar health dot, and the provider cards' empty state —
/// resolves through this projection so one account never speaks for another.
nonisolated enum CodexAccountAccessProjection {
    /// A recorded probe result always wins. The shared flag is a fallback for
    /// the default sentinel only, because it predates the per-account map and
    /// is still written by the default profile's own refresh.
    static func isAuthenticated(
        account: CodexAccount,
        accountAccess: [UUID: Bool],
        defaultHasAccess: Bool
    ) -> Bool {
        accountAccess[account.id] ?? (account.isDefault && defaultHasAccess)
    }

    /// Provider-level connection state: Codex is reachable when *any* of the
    /// supplied accounts has a usable login.
    static func hasAnyAccess(
        accounts: [CodexAccount],
        accountAccess: [UUID: Bool],
        defaultHasAccess: Bool
    ) -> Bool {
        accounts.contains {
            isAuthenticated(
                account: $0,
                accountAccess: accountAccess,
                defaultHasAccess: defaultHasAccess
            )
        }
    }
}
