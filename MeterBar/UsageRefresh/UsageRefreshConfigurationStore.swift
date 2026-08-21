import Foundation
import MeterBarShared

/// Cross-process provider configuration needed for a safe CLI refresh.
///
/// The bundled CLI cannot rely on an App Group `UserDefaults` suite: without
/// the app entitlement it resolves a separate preferences domain. The app
/// therefore mirrors only non-secret refresh configuration to explicit files
/// beside the shared metrics cache.
nonisolated enum UsageRefreshConfigurationStore {
    struct Snapshot: Equatable, Sendable {
        let hiddenServices: Set<ServiceType>
        let claudeAccounts: [ClaudeCodeAccount]
        let codexAccounts: [CodexAccount]
        let grokAccounts: [GrokAccount]
        let openRouterAccounts: [OpenRouterAccount]

        init(
            hiddenServices: Set<ServiceType>,
            claudeAccounts: [ClaudeCodeAccount],
            codexAccounts: [CodexAccount],
            grokAccounts: [GrokAccount] = [.defaultAccount],
            openRouterAccounts: [OpenRouterAccount] = [.defaultAccount]
        ) {
            self.hiddenServices = hiddenServices
            self.claudeAccounts = claudeAccounts
            self.codexAccounts = codexAccounts
            self.grokAccounts = grokAccounts
            self.openRouterAccounts = openRouterAccounts
        }
    }

    private static let visibilityFileName = "refresh-provider-visibility-v1.json"
    private static let claudeAccountsFileName = "refresh-claude-accounts-v1.json"
    private static let codexAccountsFileName = "refresh-codex-accounts-v1.json"
    private static let grokAccountsFileName = "refresh-grok-accounts-v1.json"
    private static let openRouterAccountsFileName = "refresh-openrouter-accounts-v1.json"

    static func saveVisibility(
        _ hiddenServices: Set<ServiceType>,
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        write(hiddenServices.map(\.rawValue).sorted(), fileName: visibilityFileName, directory: directory)
    }

    static func saveClaudeAccounts(
        _ accounts: [ClaudeCodeAccount],
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        write(accounts, fileName: claudeAccountsFileName, directory: directory)
    }

    static func saveCodexAccounts(
        _ accounts: [CodexAccount],
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        write(accounts, fileName: codexAccountsFileName, directory: directory)
    }

    static func saveGrokAccounts(
        _ accounts: [GrokAccount],
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        write(accounts, fileName: grokAccountsFileName, directory: directory)
    }

    static func saveOpenRouterAccounts(
        _ accounts: [OpenRouterAccount],
        directory: URL? = SharedMetricsStore.containerURL
    ) {
        write(accounts, fileName: openRouterAccountsFileName, directory: directory)
    }

    /// Fail closed unless the original three projections exist and decode.
    /// Grok's account projection is additive and optional so a CLI bundled with
    /// this version can still refresh after an older app wrote the v1 files.
    static func load(directory: URL? = SharedMetricsStore.containerURL) -> Snapshot? {
        guard let directory,
              let hiddenRaw: [String] = read(fileName: visibilityFileName, directory: directory),
              let claudeAccounts: [ClaudeCodeAccount] = read(
                  fileName: claudeAccountsFileName,
                  directory: directory
              ),
              let codexAccounts: [CodexAccount] = read(
                  fileName: codexAccountsFileName,
                  directory: directory
              ),
              hiddenRaw.allSatisfy({ ServiceType(rawValue: $0) != nil }) else {
            return nil
        }

        return Snapshot(
            hiddenServices: Set(hiddenRaw.compactMap(ServiceType.init(rawValue:))),
            claudeAccounts: claudeAccounts,
            codexAccounts: codexAccounts,
            grokAccounts: read(fileName: grokAccountsFileName, directory: directory)
                ?? [.defaultAccount],
            openRouterAccounts: read(fileName: openRouterAccountsFileName, directory: directory)
                ?? [.defaultAccount]
        )
    }

    private static func write<T: Encodable>(_ value: T, fileName: String, directory: URL?) {
        guard let directory,
              let data = try? JSONEncoder().encode(value) else {
            return
        }
        try? SecureFileWriter.write(data, to: directory.appendingPathComponent(fileName))
    }

    private static func read<T: Decodable>(fileName: String, directory: URL) -> T? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
