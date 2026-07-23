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
    }

    private static let visibilityFileName = "refresh-provider-visibility-v1.json"
    private static let claudeAccountsFileName = "refresh-claude-accounts-v1.json"
    private static let codexAccountsFileName = "refresh-codex-accounts-v1.json"

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

    /// Fail closed unless all three configuration projections exist and decode.
    /// A partial snapshot could silently re-enable providers or drop accounts.
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
            codexAccounts: codexAccounts
        )
    }

    private static func write<T: Encodable>(_ value: T, fileName: String, directory: URL?) {
        guard let directory,
              let data = try? JSONEncoder().encode(value) else {
            return
        }
        try? data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
    }

    private static func read<T: Decodable>(fileName: String, directory: URL) -> T? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
