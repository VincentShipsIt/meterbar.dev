import Foundation
import MeterBarShared

// MARK: - RouteCLIResponse

/// Version 1 contract for `meterbar route --json`.
///
/// The decision fields come straight from `RoutingDecision`, so the app and the
/// CLI render one answer. What this adds is what only a command has: the
/// stable exit code, the time it checked, and the usage-error shape `guard`
/// already established. A field is omitted when it is not known; nothing here
/// is a placeholder zero.
nonisolated struct RouteCLIResponse: CLIJSONDocument {
    static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    let outcome: String
    let exitCode: Int32
    let checkedAt: Date
    let task: RoutingTaskSummary?
    let policy: PolicyInfo?
    let recommendation: RoutingRoute?
    let fallbacks: [RoutingRoute]?
    let rejected: [RoutingRejection]?
    let reasons: [RoutingReason]?
    let message: String
    let error: ErrorDetail?

    struct PolicyInfo: Encodable, Equatable {
        /// True when the user stored their own policy for this task; false when
        /// the shipped default decided.
        let customized: Bool
    }

    struct ErrorDetail: Encodable, Equatable {
        let code: String
        let message: String
        let flag: String?
        let value: String?
    }

    init(decision: RoutingDecision, customized: Bool, notices: [RoutingReason]) {
        outcome = decision.outcome.rawValue
        exitCode = decision.exitCode
        checkedAt = decision.evaluatedAt
        task = decision.task
        policy = PolicyInfo(customized: customized)
        recommendation = decision.recommendation
        fallbacks = decision.fallbacks
        rejected = decision.rejected
        reasons = decision.reasons + notices
        message = decision.summary
        error = nil
    }

    init(failure: RouteUsageFailure, checkedAt: Date) {
        outcome = "usageError"
        exitCode = RoutingOutcome.usageErrorExitCode
        self.checkedAt = checkedAt
        task = nil
        policy = nil
        recommendation = nil
        fallbacks = nil
        rejected = nil
        reasons = nil
        message = failure.message
        error = ErrorDetail(code: failure.code, message: failure.message, flag: failure.flag, value: failure.value)
    }
}

// MARK: - RouteUsageFailure

/// A caller-supplied input `meterbar route` could not use.
nonisolated struct RouteUsageFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
    let flag: String?
    let value: String?
}
