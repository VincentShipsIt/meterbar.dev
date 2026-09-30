import Foundation

// MARK: - RoutingOutcome

/// The top-level answer to "where should this task go?".
///
/// The numbers are the `meterbar route` exit codes and follow `meterbar guard`
/// so a script that already understands one understands the other: 11 means
/// a known capability, enablement, policy, or quota restriction applies; 12 means it has nothing
/// trustworthy to say. 13, a usage error, never comes from the router — it is
/// raised before a task is resolved — so it is a constant here rather than a
/// case.
public enum RoutingOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    /// A route was chosen.
    case recommended
    /// Every candidate was rejected, with at least one known capability,
    /// enablement, policy, or quota restriction.
    case noEligibleCandidate
    /// No candidate had fresh, readable quota data, so nothing can be judged.
    case dataUnavailable

    public static let usageErrorExitCode: Int32 = 13

    public var exitCode: Int32 {
        switch self {
        case .recommended: 0
        case .noEligibleCandidate: 11
        case .dataUnavailable: 12
        }
    }
}

// MARK: - RoutingRejectionCode

/// Why a candidate was removed before scoring. Raw values are the stable
/// version 1 tokens in `docs/cli-json-schema.md`; new codes may be added.
public enum RoutingRejectionCode: String, Codable, CaseIterable, Equatable, Sendable {
    case providerDisabled = "provider_disabled"
    case providerUnsupported = "provider_unsupported"
    case providerNotPermitted = "provider_not_permitted"
    case accountNotPermitted = "account_not_permitted"
    case snapshotMissing = "snapshot_missing"
    case snapshotStale = "snapshot_stale"
    case noQuotaWindow = "no_quota_window"
    case estimateNotAllowed = "estimate_not_allowed"
    case quotaExhausted = "quota_exhausted"
    case belowMinimumHeadroom = "below_minimum_headroom"
    case deficitExceedsLimit = "deficit_exceeds_limit"
    case providerUnhealthy = "provider_unhealthy"

    /// True when the rejection says MeterBar could not read the quota, rather
    /// than that capability, enablement, quota, or policy forbids the route. Decides between
    /// `noEligibleCandidate` and `dataUnavailable`.
    public var isDataProblem: Bool {
        switch self {
        case .snapshotMissing,
             .snapshotStale,
             .noQuotaWindow,
             .providerUnhealthy:
            true
        case .providerDisabled,
             .providerUnsupported,
             .providerNotPermitted,
             .accountNotPermitted,
             .estimateNotAllowed,
             .quotaExhausted,
             .belowMinimumHeadroom,
             .deficitExceedsLimit:
            false
        }
    }
}

// MARK: - RoutingReasonCode

/// Why a route scored the way it did, or a note about the decision as a whole.
/// Raw values are the stable version 1 tokens; new codes may be added.
public enum RoutingReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
    case quotaHeadroom = "quota_headroom"
    case preferredProvider = "preferred_provider"
    case preferredAccount = "preferred_account"
    case aheadOfPace = "ahead_of_pace"
    case behindPace = "behind_pace"
    case resetSoon = "reset_soon"
    case includedQuota = "included_quota"
    case meteredUsage = "metered_usage"
    case estimatedQuota = "estimated_quota"
    case healthDegraded = "health_degraded"
    case onlyEligibleCandidate = "only_eligible_candidate"
    case tieBreakApplied = "tie_break_applied"
    case noCandidates = "no_candidates"
    case policyUnreadable = "policy_unreadable"
    case policyUnsupportedVersion = "policy_unsupported_version"
    case policyMigrationFailed = "policy_migration_failed"
}

// MARK: - RoutingReason

/// A stable machine code and the sentence a person reads for it.
public struct RoutingReason: Codable, Equatable, Sendable {
    public let code: RoutingReasonCode
    public let message: String

    public init(code: RoutingReasonCode, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - RoutingTaskSummary

/// The task a decision answers, by stable id and display name.
public struct RoutingTaskSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let builtIn: Bool

    public init(policy: RoutingPolicy) {
        id = policy.task.rawValue
        name = policy.name
        builtIn = policy.task.isBuiltIn
    }
}

// MARK: - RoutingAccountSummary

/// The account a route names. The label is sanitised (`RoutingLabel`) and the
/// id is the same UUID `meterbar usage --json` prints as `accountId`.
public struct RoutingAccountSummary: Codable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: UUID, label: String) {
        self.id = id.uuidString
        self.label = label
    }
}

// MARK: - RoutingModelSelection

/// The model the route asks for: a provider-neutral tier plus the user's own
/// alias when they configured one.
public struct RoutingModelSelection: Codable, Equatable, Sendable {
    public let tier: String
    public let alias: String?

    public init(tier: RoutingModelTier, alias: String?) {
        self.tier = tier.rawValue
        self.alias = alias
    }
}

// MARK: - RoutingPaceSummary

public struct RoutingPaceSummary: Codable, Equatable, Sendable {
    /// `onPace`, `reserve`, or `deficit`.
    public let stage: String
    /// Points behind (positive) or ahead of (negative) sustainable pace,
    /// rounded to one decimal so equal inputs print equal bytes.
    public let deltaPercent: Double

    public init(pace: UsagePace) {
        switch pace.stage {
        case .onPace: stage = "onPace"
        case .reserve: stage = "reserve"
        case .deficit: stage = "deficit"
        }
        deltaPercent = (pace.deltaPercent * 10).rounded() / 10
    }
}

// MARK: - RoutingQuotaSummary

/// The quota window a route or rejection was judged on.
public struct RoutingQuotaSummary: Codable, Equatable, Sendable {
    /// `session` or `weekly`: the provider-blocking slot, as in `guard`.
    public let window: String
    public let periodKind: String?
    public let percentLeft: Int
    public let quotaBand: String
    public let estimated: Bool
    public let resetAt: Date?
    public let pace: RoutingPaceSummary?
}

// MARK: - RoutingFreshness

/// How old the snapshot behind a decision was.
public struct RoutingFreshness: Codable, Equatable, Sendable {
    public let lastUpdated: Date
    public let ageSeconds: Double
    public let isStale: Bool

    public init(lastUpdated: Date, now: Date, stalenessThreshold: TimeInterval) {
        let age = max(0, now.timeIntervalSince(lastUpdated))
        self.lastUpdated = lastUpdated
        ageSeconds = age.rounded()
        isStale = age > stalenessThreshold
    }
}

// MARK: - RoutingRoute

/// One recommended or fallback route.
public struct RoutingRoute: Codable, Equatable, Sendable {
    /// 1 for the recommendation, 2... for fallbacks in order.
    public let rank: Int
    public let provider: String
    public let providerName: String
    public let account: RoutingAccountSummary?
    public let model: RoutingModelSelection
    public let score: Int
    public let quota: RoutingQuotaSummary
    public let freshness: RoutingFreshness
    public let reasons: [RoutingReason]

    /// The provider as a `ServiceType`, for in-process callers.
    public var service: ServiceType? {
        ServiceType.fromCLIIdentifier(provider)
    }
}

// MARK: - RoutingRejection

/// A candidate that could not be routed to, and the first rule that said so.
public struct RoutingRejection: Codable, Equatable, Sendable {
    public let provider: String
    public let providerName: String
    public let account: RoutingAccountSummary?
    public let code: RoutingRejectionCode
    public let message: String
    public let freshness: RoutingFreshness?
}

// MARK: - RoutingDecision

/// Version 1 routing decision: the shared, prompt-free answer that the CLI,
/// the app, and any later HTTP or MCP surface render.
///
/// It carries task metadata and quota state and nothing else. No token,
/// cookie, email, webhook URL, filesystem path, or prompt text can appear in
/// it: account labels pass `RoutingLabel`, and every other field is an enum
/// token, a number, or a sentence built from those.
///
/// Date fields are ISO 8601 when encoded through the CLI's `CLIJSONDocument`
/// encoder; encode with `.iso8601` to match.
public struct RoutingDecision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let outcome: RoutingOutcome
    public let evaluatedAt: Date
    public let task: RoutingTaskSummary
    public let recommendation: RoutingRoute?
    public let fallbacks: [RoutingRoute]
    public let rejected: [RoutingRejection]
    /// Notes about the decision as a whole, distinct from a route's own reasons.
    public let reasons: [RoutingReason]
    public let summary: String

    public init(
        outcome: RoutingOutcome,
        evaluatedAt: Date,
        task: RoutingTaskSummary,
        recommendation: RoutingRoute?,
        fallbacks: [RoutingRoute],
        rejected: [RoutingRejection],
        reasons: [RoutingReason],
        summary: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.outcome = outcome
        self.evaluatedAt = evaluatedAt
        self.task = task
        self.recommendation = recommendation
        self.fallbacks = fallbacks
        self.rejected = rejected
        self.reasons = reasons
        self.summary = summary
    }

    public var exitCode: Int32 {
        outcome.exitCode
    }
}
