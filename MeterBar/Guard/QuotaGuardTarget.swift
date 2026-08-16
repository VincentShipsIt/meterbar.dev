import Foundation
import MeterBarShared

/// The quota window `meterbar guard` can evaluate. Raw values match the
/// `windows[].kind` tokens already emitted by `meterbar usage --json`.
nonisolated enum QuotaGuardWindow: String, CaseIterable, Equatable, Sendable {
    case session
    case weekly
    case codeReview
    case daily
    case monthly
    case billing
    case unknown

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
        case "daily": return .daily
        case "monthly": return .monthly
        case "billing": return .billing
        case "billingcycle": return .billing
        case "unknown": return .unknown
        default: return nil
        }
    }

    static let acceptedValues = "session, weekly, code-review, daily, monthly, billing, unknown"

    /// Version 1 JSON `window` token. Cadence selectors collapse onto the
    /// compatible slot so exhaustive v1 consumers keep working.
    var cliIdentifier: String {
        switch self {
        case .session, .daily: return "session"
        case .weekly, .monthly, .billing, .unknown: return "weekly"
        case .codeReview: return "codeReview"
        }
    }

    var displayName: String {
        displayName(for: nil)
    }

    func displayName(for limit: UsageLimit?) -> String {
        if let periodKind = limit?.periodKind {
            return periodKind.guardDisplayName
        }
        switch self {
        case .session: return "session"
        case .weekly: return "weekly"
        case .codeReview: return "code review"
        case .daily: return "daily"
        case .monthly: return "monthly"
        case .billing: return "billing cycle"
        case .unknown: return "quota"
        }
    }

    func limit(in metrics: UsageMetrics) -> UsageLimit? {
        switch self {
        case .session: return metrics.sessionLimit
        case .weekly: return metrics.weeklyLimit
        case .codeReview: return metrics.codeReviewLimit
        case .daily: return Self.firstLimit(in: metrics, periodKind: .daily)
        case .monthly: return Self.firstLimit(in: metrics, periodKind: .monthly)
        case .billing: return Self.firstLimit(in: metrics, periodKind: .billing)
        case .unknown: return Self.firstLimit(in: metrics, periodKind: .unknown)
        }
    }

    /// Slot first, then overflow: a monthly allowance stored in `weeklyLimit`
    /// is addressable as `--limit monthly` without inventing a fourth slot.
    private static func firstLimit(
        in metrics: UsageMetrics,
        periodKind: UsageLimit.PeriodKind
    ) -> UsageLimit? {
        let slots = [metrics.sessionLimit, metrics.weeklyLimit, metrics.codeReviewLimit]
        if let match = slots.compactMap({ $0 }).first(where: { $0.periodKind == periodKind }) {
            return match
        }
        return metrics.additionalLimits.first { $0.periodKind == periodKind }
    }
}

nonisolated extension UsageLimit.PeriodKind {
    var guardDisplayName: String {
        switch self {
        case .session: return "session"
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .billing: return "billing cycle"
        case .unknown: return "quota"
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
        refreshTimeout: String?
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

        var timeout = QuotaGuardCLI.defaultRefreshTimeout
        if let refreshTimeout {
            guard let parsed = Double(refreshTimeout.trimmed),
                  parsed.isFinite,
                  (QuotaGuardCLI.minimumRefreshTimeout...QuotaGuardCLI.maximumRefreshTimeout)
                      .contains(parsed) else {
                return .failure(QuotaGuardFailure(
                    outcome: .usageError,
                    code: "invalid_refresh_timeout",
                    message: "Invalid --refresh-timeout value '\(refreshTimeout.trimmed)'. "
                        + "Expected \(QuotaGuardNumber.text(QuotaGuardCLI.minimumRefreshTimeout))"
                        + "...\(QuotaGuardNumber.text(QuotaGuardCLI.maximumRefreshTimeout)) seconds.",
                    flag: "--refresh-timeout",
                    value: refreshTimeout.trimmed
                ))
            }
            timeout = parsed
        }

        let trimmedConfigDirectory = configDirectory?.trimmed
        if let trimmedConfigDirectory, !trimmedConfigDirectory.isEmpty {
            guard service.supportsGuardConfigDirectory else {
                return .failure(QuotaGuardFailure(
                    outcome: .usageError,
                    code: "unsupported_config_dir",
                    message: "--config-dir is not supported for \(service.displayName). "
                        + "Only Claude Code, OpenAI Codex, and Grok have per-account config directories.",
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
            refreshTimeout: timeout
        ))
    }
}

/// Default per-provider configuration directories, injected so account matching
/// is testable without touching the real environment.
nonisolated struct QuotaGuardDefaultDirectories: Equatable, Sendable {
    let claude: String
    let codex: String
    let grok: String

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
            codex: codex,
            grok: GrokHomeDirectory.path(
                environment: environment,
                realHomeDirectory: realHomeDirectory
            )
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

nonisolated private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
