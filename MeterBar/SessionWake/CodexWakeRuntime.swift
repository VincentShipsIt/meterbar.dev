import Foundation

/// `WakeProviderRuntime` for Codex — binds Codex discovery, the Codex quota
/// authority, and the Codex process-runner factory to one selected account
/// (CODEX_HOME) so the shared orchestration never sees `CodexAccount`.
nonisolated struct CodexWakeRuntime: WakeProviderRuntime {
    let account: CodexAccount
    private let discovery: CodexSessionDiscovery
    private let authority: WakeQuotaAuthority<CodexAccount>
    private let makeRunnerForAccount: @Sendable (CodexAccount) -> WakeExecuting

    init(
        account: CodexAccount,
        discovery: CodexSessionDiscovery = CodexSessionDiscovery(),
        authority: WakeQuotaAuthority<CodexAccount> = WakeQuotaAuthority(provider: LiveCodexWakeQuotaProvider()),
        makeRunner: @escaping @Sendable (CodexAccount) -> WakeExecuting
    ) {
        self.account = account
        self.discovery = discovery
        self.authority = authority
        self.makeRunnerForAccount = makeRunner
    }

    var provider: WakeProvider { .codex }
    var accountLabel: String? { account.homeDirectory }

    func discover(ledger: ReplayLedger) async -> [WakeSessionCandidate] {
        await discovery.discover(codexHome: account.homeDirectory, ledger: ledger)
    }

    func freshQuota() async -> WakeQuota {
        await authority.freshQuota(account: account)
    }

    func makeRunner() -> WakeExecuting {
        makeRunnerForAccount(account)
    }
}
