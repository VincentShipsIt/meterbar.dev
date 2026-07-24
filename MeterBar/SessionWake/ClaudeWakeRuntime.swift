import Foundation

/// `WakeProviderRuntime` for Claude Code — a thin adapter binding the existing
/// Claude discovery, quota authority, and process-runner factory to one
/// selected account so the shared orchestration never sees `ClaudeCodeAccount`.
nonisolated struct ClaudeWakeRuntime: WakeProviderRuntime {
    let account: ClaudeCodeAccount
    private let discovery: SessionDiscovery
    private let authority: WakeQuotaAuthority<ClaudeCodeAccount>
    private let makeRunnerForAccount: @Sendable (ClaudeCodeAccount) -> WakeExecuting

    init(
        account: ClaudeCodeAccount,
        discovery: SessionDiscovery = SessionDiscovery(),
        authority: WakeQuotaAuthority<ClaudeCodeAccount> = WakeQuotaAuthority(provider: LiveWakeQuotaProvider()),
        makeRunner: @escaping @Sendable (ClaudeCodeAccount) -> WakeExecuting
    ) {
        self.account = account
        self.discovery = discovery
        self.authority = authority
        self.makeRunnerForAccount = makeRunner
    }

    var provider: WakeProvider { .claude }
    var accountLabel: String? { account.configDirectory }

    func discover(ledger: ReplayLedger) async -> [WakeSessionCandidate] {
        await discovery.discover(configDirectory: account.configDirectory, ledger: ledger)
    }

    func freshQuota() async -> WakeQuota {
        await authority.freshQuota(account: account)
    }

    func makeRunner() -> WakeExecuting {
        makeRunnerForAccount(account)
    }
}
