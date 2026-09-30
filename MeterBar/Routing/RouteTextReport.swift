import Foundation
import MeterBarShared

/// The human-readable form of a routing decision, for `meterbar route`
/// without `--json`. English only, like the other CLI reports; the JSON tokens
/// are the localisation-stable surface.
nonisolated enum RouteTextReport {
    struct Report: Equatable {
        /// The line that answers the question. Always printed on standard output.
        let headline: String
        /// Everything that explains it.
        let details: [String]
    }

    static func report(for decision: RoutingDecision, policy: RoutingPolicy, notices: [RoutingReason]) -> Report {
        guard let route = decision.recommendation else {
            return Report(
                headline: "Route: \(decision.task.name) → no route available",
                details: [decision.summary]
                    + rejectionLines(decision.rejected)
                    + (decision.reasons + notices).map { "Note: \($0.message)" }
            )
        }

        var details = ["Why:"]
        details += route.reasons.map { "  • \($0.message)" }

        let fallbackLabels = decision.fallbacks.map { WorkloadRouter.routeLabel($0, policy: policy) }
        if fallbackLabels.count == 1 {
            details.append("Fallback: \(fallbackLabels[0])")
        } else if fallbackLabels.count > 1 {
            details.append("Fallbacks:")
            details += fallbackLabels.enumerated().map { "  \($0 + 1). \($1)" }
        }

        details += (decision.reasons + notices).map { "Note: \($0.message)" }
        details += rejectionLines(decision.rejected)

        return Report(
            headline: "Route: \(decision.task.name) → \(WorkloadRouter.routeLabel(route, policy: policy))",
            details: details
        )
    }

    private static func rejectionLines(_ rejected: [RoutingRejection]) -> [String] {
        guard !rejected.isEmpty else {
            return []
        }
        return ["Skipped:"] + rejected.map { "  • \($0.message)" }
    }
}
