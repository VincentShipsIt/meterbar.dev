import Foundation
import MeterBarShared

/// Which snapshot the answer came from: the provider-wide roll-up or one
/// configured account selected with `--config-dir`.
nonisolated struct QuotaGuardAccount: Equatable, Sendable {
    enum Scope: String, Equatable, Sendable {
        case provider
        case account
    }

    let scope: Scope
    let name: String
    let id: UUID?

    static let providerWide = QuotaGuardAccount(scope: .provider, name: "All accounts", id: nil)
}

/// Freshness of the cached snapshot the decision was made from.
nonisolated struct QuotaGuardSnapshotInfo: Equatable, Sendable {
    let lastUpdated: Date
    let ageSeconds: TimeInterval
    let isStale: Bool
}

/// The evaluated quota window, expressed with the shared band/percent rules.
nonisolated struct QuotaGuardQuota: Equatable, Sendable {
    let used: Double
    let total: Double
    let percentUsed: Double
    let percentLeft: Int
    let band: QuotaBand
    let resetAt: Date?
    let resetCountdown: String?
    let estimated: Bool
}

/// The complete answer `meterbar guard` returns: one outcome, the numbers it
/// was derived from, and — when the answer is not "available" — the stable
/// failure code that explains why.
nonisolated struct QuotaGuardEvaluation: Sendable {
    let outcome: QuotaGuardOutcome
    let checkedAt: Date
    let service: ServiceType?
    let window: QuotaGuardWindow?
    let periodKind: UsageLimit.PeriodKind?
    let account: QuotaGuardAccount?
    let minRemainingPercent: Double?
    let quota: QuotaGuardQuota?
    let snapshot: QuotaGuardSnapshotInfo?
    let message: String
    let failure: QuotaGuardFailure?

    var exitCode: Int32 { outcome.exitCode }
    var isStale: Bool { snapshot?.isStale ?? false }
    var percentLeft: Int? { quota?.percentLeft }
    var band: QuotaBand? { quota?.band }
    var resetAt: Date? { quota?.resetAt }

    /// One-line human summary for terminals and log lines.
    var summaryLine: String {
        var parts = ["Guard: \(outcome.rawValue)"]
        if let service {
            let cadence = periodKind?.guardDisplayName ?? window?.displayName
            parts.append([service.displayName, cadence].compactMap { $0 }.joined(separator: " "))
        }
        if let quota {
            parts.append("\(quota.percentLeft)% left")
            parts.append(quota.band.cliIdentifier)
        } else if let failure {
            parts.append(failure.code)
        }
        if let minRemainingPercent {
            parts.append("minimum \(QuotaGuardNumber.text(minRemainingPercent))%")
        }
        if let countdown = quota?.resetCountdown {
            parts.append("resets in \(countdown)")
        }
        return parts.joined(separator: " · ")
    }

    /// A resolution failure that never reached a provider snapshot.
    static func failed(_ failure: QuotaGuardFailure, checkedAt: Date) -> QuotaGuardEvaluation {
        QuotaGuardEvaluation(
            outcome: failure.outcome,
            checkedAt: checkedAt,
            service: nil,
            window: nil,
            periodKind: nil,
            account: nil,
            minRemainingPercent: nil,
            quota: nil,
            snapshot: nil,
            message: failure.message,
            failure: failure
        )
    }
}

/// The `meterbar guard` decision core.
///
/// Pure and synchronous: it takes an already-validated target plus whatever
/// snapshot the caller found and returns the outcome. Severity comes from
/// `QuotaBand`/`QuotaMath`, so changing a shared threshold changes guard's
/// behavior without a second edit here.
nonisolated enum QuotaGuardEvaluator {
    static func evaluate(
        target: QuotaGuardTarget,
        account: QuotaGuardAccount,
        metrics: UsageMetrics?,
        now: Date = Date(),
        stalenessLimit: TimeInterval = ProviderParseHealthRecord.staleAfter
    ) -> QuotaGuardEvaluation {
        let provider = target.service.displayName

        guard let metrics else {
            return unavailable(
                target: target,
                account: account,
                now: now,
                snapshot: nil,
                code: "snapshot_missing",
                message: "No cached \(provider) usage found. "
                    + "Run `meterbar guard --refresh` or open MeterBar."
            )
        }

        let age = max(0, now.timeIntervalSince(metrics.lastUpdated))
        let snapshot = QuotaGuardSnapshotInfo(
            lastUpdated: metrics.lastUpdated,
            ageSeconds: age,
            isStale: age > stalenessLimit
        )

        guard !snapshot.isStale else {
            return unavailable(
                target: target,
                account: account,
                now: now,
                snapshot: snapshot,
                code: "snapshot_stale",
                message: "Cached \(provider) usage is \(UsageDurationText.short(seconds: age)) old "
                    + "(freshness limit \(UsageDurationText.short(seconds: stalenessLimit))). "
                    + "Re-run with --refresh."
            )
        }

        guard let limit = target.window.limit(in: metrics) else {
            return unavailable(
                target: target,
                account: account,
                now: now,
                snapshot: snapshot,
                code: "window_unavailable",
                message: "\(provider) did not report a \(target.window.displayName) quota window."
            )
        }

        // A zero/absent total would otherwise read as "100% left" through the
        // shared percent math, which is exactly the false availability the
        // guard contract forbids.
        guard limit.total > 0 else {
            return unavailable(
                target: target,
                account: account,
                now: now,
                snapshot: snapshot,
                code: "window_unavailable",
                message: "\(provider) reported a \(target.window.displayName) quota window "
                    + "without a usable total."
            )
        }

        let band = QuotaBand.forLimit(limit)
        let percentLeft = QuotaMath.percentLeft(for: limit)
        let countdown = limit.resetCountdownText(now: now)
        let quota = QuotaGuardQuota(
            used: limit.used,
            total: limit.total,
            percentUsed: limit.percentage,
            percentLeft: percentLeft,
            band: band,
            resetAt: limit.resetTime,
            resetCountdown: countdown,
            estimated: limit.isEstimated
        )
        let window = target.window.displayName(for: limit)
        let resetSentence = countdown.map { "Resets in \($0)." } ?? "Reset time unknown."

        // Exhaustion outranks the caller's threshold: the quota is blocking
        // regardless of what minimum was asked for.
        if band == .exhausted {
            return QuotaGuardEvaluation(
                outcome: .exhausted,
                checkedAt: now,
                service: target.service,
                window: target.window,
                periodKind: limit.periodKind,
                account: account,
                minRemainingPercent: target.minRemainingPercent,
                quota: quota,
                snapshot: snapshot,
                message: "\(provider) \(window) quota exhausted. \(resetSentence)",
                failure: nil
            )
        }

        if let minimum = target.minRemainingPercent, Double(percentLeft) < minimum {
            return QuotaGuardEvaluation(
                outcome: .belowThreshold,
                checkedAt: now,
                service: target.service,
                window: target.window,
                periodKind: limit.periodKind,
                account: account,
                minRemainingPercent: minimum,
                quota: quota,
                snapshot: snapshot,
                message: "\(provider) \(window) quota below threshold: \(percentLeft)% left "
                    + "(minimum \(QuotaGuardNumber.text(minimum))%). \(resetSentence)",
                failure: nil
            )
        }

        let minimumSuffix = target.minRemainingPercent
            .map { " (minimum \(QuotaGuardNumber.text($0))%)" } ?? ""
        return QuotaGuardEvaluation(
            outcome: .available,
            checkedAt: now,
            service: target.service,
            window: target.window,
            periodKind: limit.periodKind,
            account: account,
            minRemainingPercent: target.minRemainingPercent,
            quota: quota,
            snapshot: snapshot,
            message: "\(provider) \(window) quota available: \(percentLeft)% left\(minimumSuffix).",
            failure: nil
        )
    }

    private static func unavailable(
        target: QuotaGuardTarget,
        account: QuotaGuardAccount,
        now: Date,
        snapshot: QuotaGuardSnapshotInfo?,
        code: String,
        message: String
    ) -> QuotaGuardEvaluation {
        QuotaGuardEvaluation(
            outcome: .dataUnavailable,
            checkedAt: now,
            service: target.service,
            window: target.window,
            periodKind: nil,
            account: account,
            minRemainingPercent: target.minRemainingPercent,
            quota: nil,
            snapshot: snapshot,
            message: message,
            failure: QuotaGuardFailure(outcome: .dataUnavailable, code: code, message: message)
        )
    }
}

/// The snapshot `guard` will read, plus the account label describing it.
nonisolated struct QuotaGuardSelection: Sendable {
    let account: QuotaGuardAccount
    let metrics: UsageMetrics?
}

/// Maps `--config-dir` onto the account snapshots the app mirrors.
///
/// `AccountUsageSnapshot` carries no directory, so the configured account list
/// is the bridge: match the directory to an account, then that account's id to
/// its snapshot.
nonisolated enum QuotaGuardAccountResolver {
    static func resolve(
        target: QuotaGuardTarget,
        configuration: UsageRefreshConfigurationStore.Snapshot?,
        accountSnapshots: [AccountUsageSnapshot],
        providerMetrics: [ServiceType: UsageMetrics],
        defaultDirectories: QuotaGuardDefaultDirectories
    ) -> Result<QuotaGuardSelection, QuotaGuardFailure> {
        guard let requestedDirectory = target.configDirectory else {
            return .success(QuotaGuardSelection(
                account: .providerWide,
                metrics: providerMetrics[target.service]
            ))
        }

        guard let configuration else {
            return .failure(QuotaGuardFailure(
                outcome: .dataUnavailable,
                code: "account_lookup_unavailable",
                message: "MeterBar account configuration is unavailable. "
                    + "Open the MeterBar app and try again."
            ))
        }

        let home = ServiceSupport.realHomeDirectory()
        let needle = QuotaGuardPath.normalize(requestedDirectory, home: home)
        let candidates: [(id: UUID, name: String, directory: String)]
        switch target.service {
        case .claudeCode:
            candidates = configuration.claudeAccounts.map {
                (
                    id: $0.id,
                    name: $0.name,
                    directory: QuotaGuardPath.normalize(
                        $0.configDirectory ?? defaultDirectories.claude,
                        home: home
                    )
                )
            }
        case .codexCli:
            candidates = configuration.codexAccounts.map {
                (
                    id: $0.id,
                    name: $0.name,
                    directory: QuotaGuardPath.normalize(
                        $0.homeDirectory ?? defaultDirectories.codex,
                        home: home
                    )
                )
            }
        case .grok:
            candidates = configuration.grokAccounts.map {
                (
                    id: $0.id,
                    name: $0.name,
                    directory: QuotaGuardPath.normalize(
                        $0.homeDirectory ?? defaultDirectories.grok,
                        home: home
                    )
                )
            }
        default:
            return .failure(QuotaGuardFailure(
                outcome: .usageError,
                code: "unsupported_config_dir",
                message: "--config-dir is not supported for \(target.service.displayName). "
                    + "Only Claude Code, OpenAI Codex, and Grok have per-account config directories.",
                flag: "--config-dir",
                value: requestedDirectory
            ))
        }

        guard let match = candidates.first(where: { $0.directory == needle }) else {
            return .failure(QuotaGuardFailure(
                outcome: .usageError,
                code: "unknown_account",
                message: "No configured \(target.service.displayName) account uses "
                    + "config dir '\(requestedDirectory)'.",
                flag: "--config-dir",
                value: requestedDirectory
            ))
        }

        return .success(QuotaGuardSelection(
            account: QuotaGuardAccount(scope: .account, name: match.name, id: match.id),
            metrics: accountSnapshots.first { $0.id == match.id }?.metrics
        ))
    }
}

/// Echoes a caller-supplied number back without gratuitous decimals (`25`,
/// `58.5`). Formats through `String(format:)` rather than `Int(_:)` so an
/// out-of-range or non-finite flag value is reported, not a trap.
nonisolated enum QuotaGuardNumber {
    static func text(_ value: Double) -> String {
        guard value.isFinite else { return String(format: "%g", value) }
        return value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }
}
