import Foundation
import MeterBarShared

/// Credential-free fixtures for the workload router. Everything is a value at
/// a fixed instant, so no test depends on the wall clock, the Keychain, or an
/// App Group container.
enum RoutingFixtures {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A quota with no pace information: `percentLeft` is the whole story, and
    /// the reset is far enough away (3h) to earn no imminent-reset bonus.
    static func limit(
        used: Double,
        total: Double = 100,
        resetIn: TimeInterval? = 3 * 3_600,
        estimated: Bool = false
    ) -> UsageLimit {
        UsageLimit(
            used: used,
            total: total,
            resetTime: resetIn.map { now.addingTimeInterval($0) },
            windowSeconds: nil,
            isEstimated: estimated
        )
    }

    /// A five-hour session window with three hours left, so 40% of it has
    /// elapsed: `used: 40` is on pace, `used: 70` is 30 points in deficit,
    /// `used: 20` is 20 points in reserve.
    static func pacedLimit(used: Double) -> UsageLimit {
        UsageLimit(
            used: used,
            total: 100,
            resetTime: now.addingTimeInterval(3 * 3_600),
            windowSeconds: 5 * 3_600
        )
    }

    static func metrics(
        _ service: ServiceType,
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        codeReview: UsageLimit? = nil,
        age: TimeInterval = 60
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: session,
            weeklyLimit: weekly,
            codeReviewLimit: codeReview,
            lastUpdated: now.addingTimeInterval(-age)
        )
    }

    /// A provider-wide candidate with `used` percent of its session quota spent.
    static func candidate(
        _ service: ServiceType,
        used: Double = 30,
        session: UsageLimit? = nil,
        weekly: UsageLimit? = nil,
        age: TimeInterval = 60,
        health: RoutingProviderHealth = .healthy,
        enabled: Bool = true
    ) -> RoutingCandidate {
        RoutingCandidate(
            service: service,
            isEnabled: enabled,
            metrics: metrics(service, session: session ?? limit(used: used), weekly: weekly, age: age),
            health: health
        )
    }

    static func account(
        _ service: ServiceType,
        id: UUID,
        name: String = "Work",
        used: Double = 30,
        order: Int = 0
    ) -> RoutingCandidate {
        RoutingCandidate(
            service: service,
            accountID: id,
            accountName: name,
            displayOrder: order,
            metrics: metrics(service, session: limit(used: used))
        )
    }

    static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    /// A shipped default with the fields a test cares about overridden and the
    /// fallback chain wide enough to inspect.
    static func policy(
        _ task: RoutingTaskID = .implementation,
        _ configure: (inout RoutingPolicy) -> Void = { _ in }
    ) -> RoutingPolicy {
        var policy = RoutingPolicyDefaults.policy(for: task)
        policy.minimumRemainingPercent = 10
        policy.maximumDeficitPercent = nil
        policy.maximumFallbacks = 4
        configure(&policy)
        return policy.sanitized()
    }

    static func route(
        _ candidates: [RoutingCandidate],
        stalenessThreshold: TimeInterval = WorkloadRouter.defaultStalenessThreshold
    ) -> RoutingDecision {
        route(policy(), candidates, stalenessThreshold: stalenessThreshold)
    }

    static func route(
        _ policy: RoutingPolicy,
        _ candidates: [RoutingCandidate],
        stalenessThreshold: TimeInterval = WorkloadRouter.defaultStalenessThreshold
    ) -> RoutingDecision {
        WorkloadRouter.route(
            policy: policy,
            candidates: candidates,
            now: now,
            stalenessThreshold: stalenessThreshold
        )
    }
}

extension RoutingDecision {
    /// Providers in recommendation-then-fallback order.
    var chain: [String] {
        ((recommendation.map { [$0] } ?? []) + fallbacks).map(\.provider)
    }

    var rejectionCodes: [RoutingRejectionCode] {
        rejected.map(\.code)
    }
}
