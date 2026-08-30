import Foundation

/// A quota window considered by the provider-wide availability policy.
///
/// Callers project their surface-specific limit models into these candidates,
/// then use the returned IDs to render the same blocked state everywhere.
public struct ProviderBlockingCandidate: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case session
        case weekly
        /// A visible quota that does not gate normal provider usage, such as a
        /// model-scoped or code-review allowance.
        case secondary
        /// A pool with its own availability state, separate from the parent
        /// provider. Cursor's Grok Bot allowance is the current example.
        case independentSubPool
    }

    public let id: String
    public let role: Role
    public let limit: UsageLimit

    public init(id: String, role: Role, limit: UsageLimit) {
        self.id = id
        self.role = role
        self.limit = limit
    }

    public var isProviderWindow: Bool {
        role == .session || role == .weekly
    }
}

public struct ProviderBlockingEvaluation: Equatable, Sendable {
    /// Exhausted windows that make the parent provider unavailable.
    public let providerBlockers: [ProviderBlockingCandidate]
    /// Exhausted pools that are unavailable independently of the parent.
    public let independentSubPoolBlockers: [ProviderBlockingCandidate]
}

public struct ProviderBlockingHeadline: Equatable, Sendable {
    public let blocker: ProviderBlockingCandidate
    /// A future reset, or a just-due reset inside the grace period. `nil`
    /// prevents stale provider data from showing a reset long in the past.
    public let visibleResetTime: Date?
}

/// Cross-surface provider availability policy shared by the app and widgets.
public enum ProviderBlockingPolicy {
    public static let resetDueGracePeriod: TimeInterval = 5 * 60

    public static func evaluate(
        service: ServiceType,
        extraUsage: ExtraUsageStatus?,
        candidates: [ProviderBlockingCandidate]
    ) -> ProviderBlockingEvaluation {
        let independent = candidates.filter {
            $0.role == .independentSubPool
                && !$0.limit.isEstimated
                && $0.limit.isAtLimit
        }

        guard extraUsage?.state != .on else {
            return ProviderBlockingEvaluation(
                providerBlockers: [],
                independentSubPoolBlockers: independent
            )
        }

        let providerWindows = candidates.filter(\.isProviderWindow)
        let exhausted = providerWindows.filter {
            !$0.limit.isEstimated && $0.limit.isAtLimit
        }
        let hasCursorSpilloverPools = service == .cursor
            && providerWindows.count >= 2
            && providerWindows.allSatisfy {
                ServiceType.isCursorIncludedPool(total: $0.limit.total)
            }
        let providerBlockers = hasCursorSpilloverPools && exhausted.count != providerWindows.count
            ? []
            : exhausted

        return ProviderBlockingEvaluation(
            providerBlockers: providerBlockers,
            independentSubPoolBlockers: independent
        )
    }

    /// Picks the blocking row whose reset determines availability. Unknown
    /// reset data wins over a known date so surfaces never promise an earlier
    /// recovery. When all resets are known, the latest reset wins because every
    /// blocking window must recover first.
    public static func headline(
        from blockers: [ProviderBlockingCandidate],
        now: Date,
        gracePeriod: TimeInterval = resetDueGracePeriod
    ) -> ProviderBlockingHeadline? {
        guard !blockers.isEmpty else { return nil }
        if let unknownReset = blockers.first(where: { $0.limit.resetTime == nil }) {
            return ProviderBlockingHeadline(blocker: unknownReset, visibleResetTime: nil)
        }

        let future = blockers.filter { ($0.limit.resetTime ?? .distantPast) > now }
        if let latest = future.max(by: {
            ($0.limit.resetTime ?? .distantPast) < ($1.limit.resetTime ?? .distantPast)
        }) {
            return ProviderBlockingHeadline(blocker: latest, visibleResetTime: latest.limit.resetTime)
        }

        guard let mostRecent = blockers.max(by: {
            ($0.limit.resetTime ?? .distantPast) < ($1.limit.resetTime ?? .distantPast)
        }) else {
            return nil
        }
        let resetTime = mostRecent.limit.resetTime
        let isRecentlyDue = resetTime.map { now.timeIntervalSince($0) <= gracePeriod } ?? false
        return ProviderBlockingHeadline(
            blocker: mostRecent,
            visibleResetTime: isRecentlyDue ? resetTime : nil
        )
    }
}
