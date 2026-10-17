import Foundation
import MeterBarShared

/// What the Routing page shows: one answer per task, from the same pure
/// `WorkloadRouter` that `meterbar route` uses. Read-only. It carries nothing
/// the router's own text report would not print, so no path, token, or prompt
/// can reach the screen.
nonisolated struct RoutingPreview: Equatable {
    struct Skipped: Equatable, Identifiable {
        let code: RoutingRejectionCode
        let message: String
        /// True when MeterBar could not read the quota, as opposed to a rule
        /// (capability, quota, policy) ruling the route out.
        let isDataProblem: Bool

        var id: String { "\(code.rawValue):\(message)" }
    }

    struct Row: Equatable, Identifiable {
        let taskID: String
        let taskName: String
        let isCustomized: Bool
        let outcome: RoutingOutcome
        /// "Codex · Work · standard model", or "No route available".
        let headline: String
        let summary: String
        /// Why the recommended route won; empty when there is none.
        let reasons: [String]
        /// Fallback routes in the order the router would try them.
        let fallbacks: [String]
        let skipped: [Skipped]

        var id: String { taskID }
        var isBlocked: Bool { outcome != .recommended }
    }

    static let noRouteHeadline = "No route available"

    let rows: [Row]
    /// A policy-file problem worth showing above the list.
    let notice: String?

    static func make(
        catalog: RoutingPolicyCatalog,
        notice: RoutingReason?,
        candidates: [RoutingCandidate],
        now: Date
    ) -> RoutingPreview {
        RoutingPreview(
            rows: catalog.policies.map { policy in
                row(for: policy, catalog: catalog, candidates: candidates, now: now)
            },
            notice: notice?.message
        )
    }

    private static func row(
        for policy: RoutingPolicy,
        catalog: RoutingPolicyCatalog,
        candidates: [RoutingCandidate],
        now: Date
    ) -> Row {
        let decision = WorkloadRouter.route(policy: policy, candidates: candidates, now: now)
        return Row(
            taskID: decision.task.id,
            taskName: decision.task.name,
            isCustomized: catalog.isCustomized(policy.task),
            outcome: decision.outcome,
            headline: decision.recommendation.map { WorkloadRouter.routeLabel($0, policy: policy) }
                ?? noRouteHeadline,
            summary: decision.summary,
            reasons: decision.recommendation?.reasons.map(\.message) ?? [],
            fallbacks: decision.fallbacks.map { WorkloadRouter.routeLabel($0, policy: policy) },
            skipped: decision.rejected.map {
                Skipped(code: $0.code, message: $0.message, isDataProblem: $0.code.isDataProblem)
            }
        )
    }
}
