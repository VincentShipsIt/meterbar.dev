import Foundation
import MeterBarShared

/// The popover's single routing line: the chosen task and where it would go
/// right now. It asks the same pure `WorkloadRouter` as the Routing page and
/// `meterbar route`. It is shown only for a real recommendation; a blocked or
/// unknown task shows nothing here, and the Routing page explains why.
nonisolated struct PopoverRoutingLine: Equatable {
    struct Option: Equatable, Identifiable {
        let id: RoutingTaskID
        let name: String
    }

    let taskName: String
    /// "Codex · Work · standard model".
    let route: String

    var text: String { "\(taskName) → \(route)" }

    static func make(
        task: RoutingTaskID,
        catalog: RoutingPolicyCatalog,
        candidates: [RoutingCandidate],
        now: Date
    ) -> PopoverRoutingLine? {
        guard let policy = catalog.policy(for: task) else { return nil }
        let decision = WorkloadRouter.route(policy: policy, candidates: candidates, now: now)
        guard decision.outcome == .recommended, let recommendation = decision.recommendation else {
            return nil
        }
        return PopoverRoutingLine(
            taskName: policy.name,
            route: WorkloadRouter.routeLabel(recommendation, policy: policy)
        )
    }

    /// Tasks the user can pick on the Routing page, in listing order.
    static func options(in catalog: RoutingPolicyCatalog) -> [Option] {
        catalog.policies.map { Option(id: $0.task, name: $0.name) }
    }
}
