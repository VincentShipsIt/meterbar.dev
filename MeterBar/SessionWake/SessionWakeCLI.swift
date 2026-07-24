import Foundation
import MeterBarShared

/// The single public entry point the bundled `meterbar wake` command calls.
///
/// Keeping one narrow facade (rather than exposing the whole engine) means the
/// CLI stays a thin wrapper over the same native discovery / quota / runner /
/// ledger the app uses, and MeterBar's public surface doesn't balloon.
public enum SessionWakeCLI {
    /// Shared app-group key used by both the app and bundled CLI.
    public static let sharedFeatureEnabledKey = "SessionWakeFeatureEnabled"

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
        guard isFeatureEnabled() else {
            let message = "Session Wake is disabled by MeterBar's master feature switch."
            let response = WakeCLIResponse.from(
                candidates: [],
                outcome: .validationFailure,
                provider: request.provider,
                dryRun: request.dryRun,
                account: request.configDirectory,
                message: message
            )
            return result(from: response)
        }

        guard let provider = WakeProvider.parse(request.provider) else {
            let response = WakeCLIResponse.from(
                candidates: [],
                outcome: .validationFailure,
                provider: request.provider.lowercased(),
                dryRun: request.dryRun,
                account: request.configDirectory,
                message: "Unsupported provider '\(request.provider)'. Use 'claude' or 'codex'."
            )
            return result(from: response)
        }

        let mode: WakePermissionMode = (request.permissionMode.lowercased() == "bypass") ? .bypass : .safe
        let engine = WakeCLIEngine(shouldCancel: request.shouldCancel)
        let runtime = makeRuntime(
            provider: provider,
            configDirectory: request.configDirectory,
            mode: mode,
            bypassAcknowledged: request.bypassAcknowledged
        )

        let response = await engine.run(runtime: runtime, dryRun: request.dryRun, limit: request.limit)
        return result(from: response)
    }

    /// Build the provider-specific runtime the engine drives. For Codex the
    /// `configDirectory` request field is reinterpreted as CODEX_HOME.
    private static func makeRuntime(
        provider: WakeProvider,
        configDirectory: String?,
        mode: WakePermissionMode,
        bypassAcknowledged: Bool
    ) -> WakeProviderRuntime {
        switch provider {
        case .claude:
            let account = resolveAccount(configDirectory: configDirectory)
            return ClaudeWakeRuntime(account: account) { runnerAccount in
                WakeProcessRunner.claude(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypassAcknowledged
                )
            }
        case .codex:
            let account = resolveCodexAccount(homeDirectory: configDirectory)
            return CodexWakeRuntime(account: account) { runnerAccount in
                WakeProcessRunner.codex(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypassAcknowledged
                )
            }
        }
    }

    /// Missing means enabled for compatibility with v1.7.0 installs. Only an
    /// explicit false activates the kill-switch.
    public static func isFeatureEnabled(userDefaults: UserDefaults? = nil) -> Bool {
        let defaults = userDefaults ?? UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier)
        guard let defaults else { return true }
        guard defaults.object(forKey: sharedFeatureEnabledKey) != nil else { return true }
        return defaults.bool(forKey: sharedFeatureEnabledKey)
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

    private static func result(from response: WakeCLIResponse) -> Result {
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

    /// The app-group key the app writes the selected Codex wake account's
    /// CODEX_HOME to. Read-only from the CLI.
    public static let sharedCodexHomeKey = "SessionWakeCodexHomeDir"

    /// The Codex CODEX_HOME the app shares via the app-group domain.
    public static func sharedCodexHomeDirectory() -> String? {
        guard let shared = UserDefaults(suiteName: SharedMetricsStore.appGroupIdentifier) else {
            return nil
        }
        let value = shared.string(forKey: sharedCodexHomeKey)?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Resolve the Codex wake account. An explicit `--config-dir` is treated as
    /// CODEX_HOME; otherwise the app-group value the app shares, then the
    /// default profile (`CODEX_HOME` env / `~/.codex`).
    private static func resolveCodexAccount(homeDirectory: String?) -> CodexAccount {
        let explicit = homeDirectory?.trimmingCharacters(in: .whitespaces)
        if let explicit, !explicit.isEmpty {
            return CodexAccount(id: UUID(), name: "cli", homeDirectory: explicit)
        }
        if let shared = sharedCodexHomeDirectory() {
            return CodexAccount(id: UUID(), name: "shared", homeDirectory: shared)
        }
        return .defaultAccount
    }
}
