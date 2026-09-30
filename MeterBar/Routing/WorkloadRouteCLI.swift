import Foundation
import MeterBarShared

/// Public facade used by the bundled `meterbar route` command.
///
/// Recommendation only. It reads the cached snapshots, the policy file, and the
/// configuration MeterBar already mirrors for the CLI, asks the pure
/// `WorkloadRouter`, and prints the answer. It launches no subprocess, switches
/// no credential, mutates no account, and never sees a prompt — the only thing
/// it can do beyond reading is `--refresh`, the same bounded refresh
/// `meterbar guard --refresh` runs.
nonisolated public enum WorkloadRouteCLI {
    public static let defaultRefreshTimeout = QuotaGuardCLI.defaultRefreshTimeout

    public struct Result: Sendable {
        public let jsonOutput: String
        /// The line that answers the question; always standard output.
        public let headline: String
        /// The explanation. Standard output for a route, standard error when
        /// there is none, so `route >/dev/null` still surfaces why.
        public let details: [String]
        public let exitCode: Int32
    }

    public struct Request: Sendable {
        /// Raw `--task` text; parsed in the core so a bad value exits with the
        /// documented usage code instead of ArgumentParser's generic one.
        public let task: String?
        public let refresh: Bool
        public let refreshTimeout: String?
        public let shouldCancel: @Sendable () -> Bool

        public init(
            task: String? = nil,
            refresh: Bool = false,
            refreshTimeout: String? = nil,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) {
            self.task = task
            self.refresh = refresh
            self.refreshTimeout = refreshTimeout
            self.shouldCancel = shouldCancel
        }
    }

    public static func run(_ request: Request) async -> Result {
        let policies = RoutingPolicyStore.load()

        switch resolve(request, catalog: policies.catalog) {
        case let .failure(failure):
            return result(
                from: RouteCLIResponse(failure: failure, checkedAt: Date()),
                report: RouteTextReport.Report(
                    headline: "Route: usage error · \(failure.code)",
                    details: [failure.message]
                )
            )
        case let .success(target):
            if request.refresh {
                // A failed refresh is not a routing failure: the cache is still
                // evaluated below and reports its own staleness.
                await CLIBoundedRefresh.run(timeout: target.refreshTimeout, shouldCancel: request.shouldCancel)
            }
            return evaluate(
                target: target,
                catalog: policies.catalog,
                notice: policies.notice,
                candidates: loadCandidates(),
                now: Date()
            )
        }
    }

    // MARK: - Input resolution

    struct Target: Equatable {
        let policy: RoutingPolicy
        let refreshTimeout: TimeInterval
    }

    static func resolve(
        _ request: Request,
        catalog: RoutingPolicyCatalog
    ) -> Swift.Result<Target, RouteUsageFailure> {
        let known = catalog.taskIDs.map(\.rawValue).joined(separator: ", ")

        guard let raw = request.task?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(RouteUsageFailure(
                code: "missing_task",
                message: "--task is required. Expected one of: \(known).",
                flag: "--task",
                value: nil
            ))
        }
        guard let id = RoutingTaskID(token: raw) else {
            let safeValue = RoutingLabel.sanitized(raw, fallback: "[redacted]")
            return .failure(RouteUsageFailure(
                code: "invalid_task",
                message: "Invalid --task value '\(safeValue)'. Expected one of: \(known).",
                flag: "--task",
                value: safeValue
            ))
        }
        guard let policy = catalog.policy(for: id) else {
            return .failure(RouteUsageFailure(
                code: "unknown_task",
                message: "Unknown task '\(id.rawValue)' for --task. Expected one of: \(known).",
                flag: "--task",
                value: id.rawValue
            ))
        }

        var timeout = defaultRefreshTimeout
        if let rawTimeout = request.refreshTimeout {
            let text = rawTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Double(text), parsed.isFinite,
                  (QuotaGuardCLI.minimumRefreshTimeout ... QuotaGuardCLI.maximumRefreshTimeout).contains(parsed) else {
                let safeValue = text.isEmpty ? text : RoutingLabel.sanitized(text, fallback: "[redacted]")
                return .failure(RouteUsageFailure(
                    code: "invalid_refresh_timeout",
                    message: "Invalid --refresh-timeout value '\(safeValue)'. Expected "
                        + "\(QuotaGuardNumber.text(QuotaGuardCLI.minimumRefreshTimeout))"
                        + "...\(QuotaGuardNumber.text(QuotaGuardCLI.maximumRefreshTimeout)) seconds.",
                    flag: "--refresh-timeout",
                    value: safeValue
                ))
            }
            timeout = parsed
        }
        return .success(Target(policy: policy, refreshTimeout: timeout))
    }

    // MARK: - Evaluation

    /// Pure once its inputs are loaded: the seam the tests drive with fixtures.
    static func evaluate(
        target: Target,
        catalog: RoutingPolicyCatalog,
        notice: RoutingReason?,
        candidates: [RoutingCandidate],
        now: Date
    ) -> Result {
        let decision = WorkloadRouter.route(policy: target.policy, candidates: candidates, now: now)
        let notices = notice.map { [$0] } ?? []
        let response = RouteCLIResponse(
            decision: decision,
            customized: catalog.isCustomized(target.policy.task),
            notices: notices
        )
        let report = RouteTextReport.report(for: decision, policy: target.policy, notices: notices)
        return result(from: response, report: report)
    }

    private static func loadCandidates() -> [RoutingCandidate] {
        let store = SharedDataStore.shared
        store.flushPendingWrites()
        return RoutingCandidateAssembler.assemble(
            metrics: store.loadMetrics(),
            accounts: store.loadAccountMetrics(),
            configuration: UsageRefreshConfigurationStore.load(),
            health: ProviderParseHealthStore.sharedRecords()
        )
    }

    private static func result(from response: RouteCLIResponse, report: RouteTextReport.Report) -> Result {
        Result(
            jsonOutput: (try? response.jsonString()) ?? "{}",
            headline: report.headline,
            details: report.details,
            exitCode: response.exitCode
        )
    }
}
