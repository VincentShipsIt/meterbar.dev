import Foundation

/// The safe defaults every task ships with.
///
/// Two deliberate choices shape the table below.
///
/// **No provider preference.** Which vendor is best at which kind of work is
/// an opinion that changes with every model release, and a stale opinion
/// shipped as a default would quietly steer people. Out of the box a route is
/// decided by quota headroom, pace, and health, so a one-provider user gets a
/// useful answer with nothing configured. Preference order is the user's to
/// set.
///
/// **Work-shaped thresholds.** Long sessions need more room than a one-line
/// fix, so planning demands the most headroom and the tightest pace, quick
/// edits the least. Estimated quota totals are eligible only for the
/// low-stakes tasks.
public enum RoutingPolicyDefaults {
    /// The default policy for `task`. A custom id the app has never seen gets
    /// the neutral policy named after itself.
    public static func policy(for task: RoutingTaskID) -> RoutingPolicy {
        switch task {
        case .planning:
            return make(task, tier: .premium, minimum: 30, deficit: 15)
        case .implementation:
            return make(task, tier: .standard, minimum: 20, deficit: 25)
        case .debugging:
            return make(task, tier: .standard, minimum: 15, deficit: 25)
        case .review:
            return make(task, tier: .premium, minimum: 20, deficit: 20)
        case .research:
            return make(task, tier: .standard, minimum: 15, deficit: 30, estimated: true)
        case .quickEdit:
            return make(task, tier: .economy, minimum: 5, deficit: nil, estimated: true, cost: .cost)
        default:
            return make(task, tier: .standard, minimum: 10, deficit: nil)
        }
    }

    /// The seven built-in policies in their documented order.
    public static var all: [RoutingPolicy] {
        RoutingTaskID.builtIn.map(policy(for:))
    }

    private static func make(
        _ task: RoutingTaskID,
        tier: RoutingModelTier,
        minimum: Int,
        deficit: Int?,
        estimated: Bool = false,
        cost: RoutingCostPreference = .balanced
    ) -> RoutingPolicy {
        RoutingPolicy(
            task: task,
            name: task.builtInName ?? task.rawValue,
            modelTier: tier,
            minimumRemainingPercent: minimum,
            maximumDeficitPercent: deficit,
            allowsEstimatedQuota: estimated,
            costPreference: cost
        )
    }
}
