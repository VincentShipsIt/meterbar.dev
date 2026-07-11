import Foundation
import MeterBarShared

/// The single public entry point the bundled `meterbar wake` command calls.
///
/// Keeping one narrow facade (rather than exposing the whole engine) means the
/// CLI stays a thin wrapper over the same native discovery / quota / runner /
/// ledger the app uses, and MeterBar's public surface doesn't balloon.
public enum SessionWakeCLI {
    /// Everything the command needs to render output and set an exit code.
    public struct Result: Sendable {
        /// The versioned JSON response (stdout when `--json`).
        public let jsonOutput: String
        /// A one-line human summary (stdout otherwise).
        public let summaryLine: String
        /// Machine-stable reason for a non-success outcome (stderr/diagnostic).
        public let message: String?
        /// Distinguishable process exit code.
        public let exitCode: Int32

        public init(jsonOutput: String, summaryLine: String, message: String?, exitCode: Int32) {
            self.jsonOutput = jsonOutput
            self.summaryLine = summaryLine
            self.message = message
            self.exitCode = exitCode
        }
    }

    /// Everything `meterbar wake` passes in, bundled so the entry point stays a
    /// single call.
    public struct Request: Sendable {
        public let provider: String
        public let configDirectory: String?
        public let dryRun: Bool
        public let limit: Int?
        public let permissionMode: String
        public let bypassAcknowledged: Bool
        public let shouldCancel: @Sendable () -> Bool

        public init(
            provider: String,
            configDirectory: String?,
            dryRun: Bool,
            limit: Int?,
            permissionMode: String,
            bypassAcknowledged: Bool,
            shouldCancel: @escaping @Sendable () -> Bool
        ) {
            self.provider = provider
            self.configDirectory = configDirectory
            self.dryRun = dryRun
            self.limit = limit
            self.permissionMode = permissionMode
            self.bypassAcknowledged = bypassAcknowledged
            self.shouldCancel = shouldCancel
        }
    }

    /// Run a one-shot wake. `dryRun` performs no subprocess and no mutation.
    public static func run(_ request: Request) async -> Result {
        let account = resolveAccount(configDirectory: request.configDirectory)
        let mode: WakePermissionMode = (request.permissionMode.lowercased() == "bypass") ? .bypass : .safe
        let engine = WakeCLIEngine(
            makeRunner: { runnerAccount in
                WakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: request.bypassAcknowledged,
                    // The engine holds the shared lock for the whole pass; a
                    // second same-process flock would self-contend (fd-level
                    // holders), failing every real resume.
                    assumesExternalLock: true
                )
            },
            shouldCancel: request.shouldCancel
        )

        let response = await engine.run(
            provider: request.provider,
            account: account,
            dryRun: request.dryRun,
            limit: request.limit
        )
        let json = (try? response.jsonData())
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let summary = "Session Wake: \(response.outcome.rawValue) · eligible \(response.eligibleCount)"
            + " · resumed \(response.summary.resumed) · failed \(response.summary.failed)"

        return Result(
            jsonOutput: json,
            summaryLine: summary,
            message: response.message,
            exitCode: response.outcome.exitCode
        )
    }

    /// The wake account config directory the app shares via the app-group
    /// domain — never the CLI process's own `UserDefaults.standard`.
    public static func sharedAccountConfigDirectory() -> String? {
        guard let shared = UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) else {
            return nil
        }
        let value = shared.string(forKey: sharedAccountConfigKey)?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
    }

    /// The app-group key the app writes the selected wake account's config dir to.
    public static let sharedAccountConfigKey = "SessionWakeAccountConfigDir"

    private static func resolveAccount(configDirectory: String?) -> ClaudeCodeAccount {
        let explicit = configDirectory?.trimmingCharacters(in: .whitespaces)
        if let explicit, !explicit.isEmpty {
            return ClaudeCodeAccount(id: UUID(), name: "cli", configDirectory: explicit)
        }
        if let shared = sharedAccountConfigDirectory() {
            return ClaudeCodeAccount(id: UUID(), name: "shared", configDirectory: shared)
        }
        return .defaultAccount
    }
}
