import Foundation
import MeterBarShared

/// The quota window `meterbar guard` can evaluate. Raw values match the
/// `windows[].kind` tokens already emitted by `meterbar usage --json`.
nonisolated enum QuotaGuardWindow: String, CaseIterable, Equatable, Sendable {
    case session
    case weekly
    case codeReview

    /// Accepts the documented spellings plus the hyphen/underscore and casing
    /// variants a shell script is likely to pass.
    static func parse(_ raw: String) -> QuotaGuardWindow? {
        let needle = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch needle {
        case "session": return .session
        case "weekly": return .weekly
        case "codereview": return .codeReview
        default: return nil
        }
    }

    static let acceptedValues = "session, weekly, code-review"

    var cliIdentifier: String { rawValue }

    var displayName: String {
        switch self {
        case .session: return "session"
        case .weekly: return "weekly"
        case .codeReview: return "code review"
        }
    }

    func limit(in metrics: UsageMetrics) -> UsageLimit? {
        switch self {
        case .session: return metrics.sessionLimit
        case .weekly: return metrics.weeklyLimit
        case .codeReview: return metrics.codeReviewLimit
        }
    }
}

/// Validated `meterbar guard` inputs. Every caller-supplied value is checked
/// here so an invalid flag produces the stable usage-error exit code instead of
/// ArgumentParser's generic one.
nonisolated struct QuotaGuardTarget: Equatable, Sendable {
    let service: ServiceType
    let window: QuotaGuardWindow
    /// Minimum percent of quota that must remain. `nil` means the default
    /// policy: anything short of exhaustion passes.
    let minRemainingPercent: Double?
    let configDirectory: String?
    let refreshTimeout: TimeInterval

    static func resolve(
        provider: String,
        window: String,
        minRemaining: String?,
        configDirectory: String?,
        refreshTimeout: Double
    ) -> Result<QuotaGuardTarget, QuotaGuardFailure> {
        guard let service = ServiceType.fromCLIIdentifier(provider) else {
            return .failure(QuotaGuardFailure(
                outcome: .usageError,
                code: "invalid_provider",
                message: "Unknown provider '\(provider.trimmed)' for --provider. "
                    + "Expected one of: \(ServiceType.cliIdentifiers).",
                flag: "--provider",
                value: provider.trimmed
            ))
        }

        guard let resolvedWindow = QuotaGuardWindow.parse(window) else {
            return .failure(QuotaGuardFailure(
                outcome: .usageError,
                code: "invalid_window",
                message: "Unknown quota window '\(window.trimmed)' for --limit. "
                    + "Expected one of: \(QuotaGuardWindow.acceptedValues).",
                flag: "--limit",
                value: window.trimmed
            ))
        }

        var threshold: Double?
        if let minRemaining {
            guard let parsed = Double(minRemaining.trimmed),
                  parsed.isFinite,
                  (0...100).contains(parsed) else {
                return .failure(QuotaGuardFailure(
                    outcome: .usageError,
                    code: "invalid_threshold",
                    message: "Invalid --min-remaining value '\(minRemaining.trimmed)'. "
                        + "Expected a percentage between 0 and 100.",
                    flag: "--min-remaining",
                    value: minRemaining.trimmed
                ))
            }
            threshold = parsed
        }

        guard refreshTimeout.isFinite,
              (QuotaGuardCLI.minimumRefreshTimeout...QuotaGuardCLI.maximumRefreshTimeout)
                  .contains(refreshTimeout) else {
            return .failure(QuotaGuardFailure(
                outcome: .usageError,
                code: "invalid_refresh_timeout",
                message: "Invalid --refresh-timeout value '\(QuotaGuardNumber.text(refreshTimeout))'. "
                    + "Expected \(QuotaGuardNumber.text(QuotaGuardCLI.minimumRefreshTimeout))"
                    + "...\(QuotaGuardNumber.text(QuotaGuardCLI.maximumRefreshTimeout)) seconds.",
                flag: "--refresh-timeout",
                value: QuotaGuardNumber.text(refreshTimeout)
            ))
        }

        let trimmedConfigDirectory = configDirectory?.trimmed
        if let trimmedConfigDirectory, !trimmedConfigDirectory.isEmpty {
            guard service.supportsGuardConfigDirectory else {
                return .failure(QuotaGuardFailure(
                    outcome: .usageError,
                    code: "unsupported_config_dir",
                    message: "--config-dir is not supported for \(service.displayName). "
                        + "Only Claude Code and OpenAI Codex have per-account config directories.",
                    flag: "--config-dir",
                    value: trimmedConfigDirectory
                ))
            }
        }

        return .success(QuotaGuardTarget(
            service: service,
            window: resolvedWindow,
            minRemainingPercent: threshold,
            configDirectory: trimmedConfigDirectory?.isEmpty == false ? trimmedConfigDirectory : nil,
            refreshTimeout: refreshTimeout
        ))
    }
}

/// Default per-provider configuration directories, injected so account matching
/// is testable without touching the real environment.
nonisolated struct QuotaGuardDefaultDirectories: Equatable, Sendable {
    let claude: String
    let codex: String

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        realHomeDirectory: String = ServiceSupport.realHomeDirectory()
    ) -> QuotaGuardDefaultDirectories {
        let rawCodexHome = environment["CODEX_HOME"]?.trimmed
        let codex: String
        if let rawCodexHome, !rawCodexHome.isEmpty {
            codex = QuotaGuardPath.normalize(rawCodexHome, home: realHomeDirectory)
        } else {
            codex = (realHomeDirectory as NSString).appendingPathComponent(".codex")
        }
        return QuotaGuardDefaultDirectories(
            claude: ClaudeCodeAccount.defaultConfigDirectory(
                environment: environment,
                realHomeDirectory: realHomeDirectory
            ),
            codex: codex
        )
    }
}

/// Tilde expansion + standardization so `~/.claude`, `/Users/me/.claude`, and
/// `/Users/me/.claude/` all select the same configured account.
nonisolated enum QuotaGuardPath {
    static func normalize(_ raw: String, home: String) -> String {
        var value = raw.trimmed
        if value == "~" {
            value = home
        } else if value.hasPrefix("~/") {
            value = (home as NSString).appendingPathComponent(String(value.dropFirst(2)))
        }
        value = (value as NSString).standardizingPath
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

nonisolated extension ServiceType {
    /// Only the CLI-backed providers keep per-account config directories the
    /// app mirrors for cross-process reads.
    var supportsGuardConfigDirectory: Bool {
        self == .claudeCode || self == .codexCli
    }
}

nonisolated private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
