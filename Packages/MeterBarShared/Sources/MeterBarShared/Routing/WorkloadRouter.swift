import Foundation

/// How healthy MeterBar's own reading of a provider is. Derived by the caller
/// from parse and fetch history; the router only acts on the result.
public enum RoutingProviderHealth: String, Codable, Equatable, Sendable {
    case healthy
    /// Recent failures, but not sustained: still routable, scored down.
    case degraded
    /// Sustained fetch or parse failure: the numbers cannot be trusted, and the
    /// provider is not offered new work.
    case failing
}

/// One provider or one account of a provider that could take the work.
///
/// Carries only quota state MeterBar already cached. It has no credentials,
/// no filesystem locations, and no email address, so nothing routing produces
/// from it can leak one.
public struct RoutingCandidate: Sendable {
    public let service: ServiceType
    /// `nil` for a provider-wide snapshot, which is all Cursor ever has and
    /// what a single-account setup falls back to.
    public let accountID: UUID?
    /// The user's own label for the account. Sanitised before it is shown.
    public let accountName: String?
    public let isEnabled: Bool
    /// Position among the provider's accounts; the account-priority tie-breaker.
    public let displayOrder: Int
    public let metrics: UsageMetrics?
    public let health: RoutingProviderHealth

    public init(
        service: ServiceType,
        accountID: UUID? = nil,
        accountName: String? = nil,
        isEnabled: Bool = true,
        displayOrder: Int = 0,
        metrics: UsageMetrics?,
        health: RoutingProviderHealth = .healthy
    ) {
        self.service = service
        self.accountID = accountID
        self.accountName = accountName
        self.isEnabled = isEnabled
        self.displayOrder = displayOrder
        self.metrics = metrics
        self.health = health
    }

    var accountRef: RoutingAccountRef? {
        accountID.map { RoutingAccountRef(provider: service, accountID: $0) }
    }

    var accountSummary: RoutingAccountSummary? {
        guard let accountID else { return nil }
        return RoutingAccountSummary(
            id: accountID,
            label: RoutingLabel.sanitized(
                accountName,
                fallback: RoutingLabel.fallbackAccountLabel(id: accountID)
            )
        )
    }
}

/// How the router weighs its inputs, in score points.
///
/// The score is percent-of-quota-left with bounded adjustments, so an
/// unadjusted score reads as "percent left" and every ordering can be
/// explained from numbers the route already prints. Pace and reset timing reuse
/// `ProviderRecommendationWeights` so this ranking and the dashboard's
/// "use this next" hint move together.
public enum RoutingWeights {
    /// Bonus by position in the policy's provider preference list. Large enough
    /// to decide between similar providers, small enough that a much emptier
    /// preferred provider still loses: no bonus beats 25 points of headroom.
    public static let providerPreferencePoints = [25, 15, 8, 3]

    /// Bonus for an account the policy prefers (`preferred` mode).
    public static let preferredAccountPoints = 10.0

    /// Penalty for a provider whose recent fetches have been failing.
    public static let degradedHealthPenalty = 8.0

    /// Penalty for metered (pay-per-use) spend, by the policy's cost
    /// preference. Included subscription quota never pays it.
    public static func meteredPenalty(for preference: RoutingCostPreference) -> Double {
        switch preference {
        case .headroom: return 0
        case .balanced: return 15
        case .cost: return 40
        }
    }

    /// Scales the metered penalty by the model tier: a premium request is
    /// costlier to run metered than an economy one.
    public static func tierMultiplier(for tier: RoutingModelTier) -> Double {
        switch tier {
        case .economy: return 0.5
        case .standard: return 1
        case .premium: return 1.5
        }
    }
}

/// Whether using a provider spends from an included allowance or bills per use.
public enum RoutingCostClass: Equatable, Sendable {
    /// A flat subscription's included quota: no marginal cost until it is spent.
    case included
    /// Pay-per-use credit: every request draws down real money.
    case metered

    public static func of(_ service: ServiceType) -> RoutingCostClass {
        service == .openRouter ? .metered : .included
    }
}

/// The pure, deterministic workload router.
///
/// Given a task policy and the quota state MeterBar has cached, it returns one
/// `RoutingDecision`: the best eligible route, an ordered fallback chain, and
/// the reason every other candidate was set aside. It reads no clock, no disk,
/// no network, and no credentials — `now` is injected and every input is a
/// value — so the app and the CLI evaluating identical inputs cannot disagree,
/// and it cannot launch a process or touch an account because it has no way to.
///
/// **Evaluation.** Hard filters run first, in a fixed order, and the first one
/// a candidate fails is its rejection: enabled; policy provider scope; policy
/// account scope; snapshot present; snapshot fresh; a usable quota window;
/// estimated quota allowed; not exhausted; minimum headroom; maximum pace
/// deficit; provider health. Missing, stale, malformed, or exhausted data
/// rejects — it is never read as available.
///
/// **Scoring.** Eligible candidates are scored (see `RoutingWeights`) and
/// ordered by score, then by a documented tie-breaker.
///
/// **Tie-breaker.** Equal scores fall through, in order, to: more quota left;
/// earlier in the policy's provider preference; provider order
/// (`ServiceType.sortOrder`); the account's display order; account id. The
/// last step is total, so the result never depends on input order.
public enum WorkloadRouter {
    /// Past two hours a snapshot describes a window that has likely moved on;
    /// the same bound the dashboard and `meterbar guard` use.
    public static let defaultStalenessThreshold = ProviderRecommendationPlanner.defaultStalenessThreshold

    public static func route(
        policy rawPolicy: RoutingPolicy,
        candidates: [RoutingCandidate],
        now: Date,
        stalenessThreshold: TimeInterval = defaultStalenessThreshold
    ) -> RoutingDecision {
        let policy = rawPolicy.sanitized()
        let context = Context(policy: policy, now: now, stalenessThreshold: stalenessThreshold)

        var scored: [Scored] = []
        var rejections: [RoutingRejection] = []
        for candidate in candidates.sorted(by: canonicalOrder) {
            switch evaluate(candidate, in: context) {
            case let .eligible(entry): scored.append(entry)
            case let .rejected(rejection): rejections.append(rejection)
            }
        }

        let ranked = scored.sorted { ordering($0, $1, policy: policy).isOrderedBefore }
        let chain = fallbackChain(ranked, policy: policy)
        return decision(ranked: ranked, chain: chain, rejections: rejections, context: context)
    }

    // MARK: - Evaluation

    private struct Context {
        let policy: RoutingPolicy
        let now: Date
        let stalenessThreshold: TimeInterval
    }

    private struct Scored {
        let candidate: RoutingCandidate
        let window: ProviderRecommendationWindow
        let limit: UsageLimit
        let percentLeft: Int
        let pace: UsagePace?
        let preferenceRank: Int?
        let score: Int
        let reasons: [RoutingReason]
        let freshness: RoutingFreshness
    }

    private enum Evaluation {
        case eligible(Scored)
        case rejected(RoutingRejection)
    }

    private struct WindowReading {
        let window: ProviderRecommendationWindow
        let limit: UsageLimit
        let percentLeft: Int
    }

    private static func evaluate(_ candidate: RoutingCandidate, in context: Context) -> Evaluation {
        let policy = context.policy
        let service = candidate.service

        func reject(_ code: RoutingRejectionCode, _ message: String, freshness: RoutingFreshness? = nil) -> Evaluation {
            .rejected(RoutingRejection(
                provider: service.cliIdentifier,
                providerName: service.displayName,
                account: candidate.accountSummary,
                code: code,
                message: message,
                freshness: freshness
            ))
        }

        guard candidate.isEnabled else {
            return reject(.providerDisabled, "\(subject(candidate)) is turned off in MeterBar")
        }
        if policy.providerScope == .preferredOnly, policy.preferenceRank(of: service) == nil {
            return reject(.providerNotPermitted, "\(policy.name) is limited to your preferred providers")
        }
        if let message = accountScopeViolation(candidate, policy: policy) {
            return reject(.accountNotPermitted, message)
        }
        guard let metrics = candidate.metrics else {
            return reject(.snapshotMissing, "No usage cached yet for \(subject(candidate))")
        }

        let freshness = RoutingFreshness(
            lastUpdated: metrics.lastUpdated,
            now: context.now,
            stalenessThreshold: context.stalenessThreshold
        )
        guard !freshness.isStale else {
            return reject(
                .snapshotStale,
                "\(subject(candidate)) usage is \(UsageDurationText.short(seconds: freshness.ageSeconds)) old "
                    + "(limit \(UsageDurationText.short(seconds: context.stalenessThreshold)))",
                freshness: freshness
            )
        }

        let blockingLimits = [metrics.sessionLimit, metrics.weeklyLimit].compactMap { $0 }
        guard blockingLimits.allSatisfy(isUsableBlockingLimit) else {
            return reject(
                .noQuotaWindow,
                "\(subject(candidate)) reported a malformed session or weekly quota window",
                freshness: freshness
            )
        }
        let readings = windowReadings(of: metrics)
        guard !readings.isEmpty else {
            return reject(
                .noQuotaWindow,
                "\(subject(candidate)) reported no usable session or weekly quota window",
                freshness: freshness
            )
        }

        let blockers = ProviderBlockingPolicy.evaluate(
            service: service,
            extraUsage: nil,
            candidates: readings.map {
                ProviderBlockingCandidate(
                    id: $0.window.rawValue,
                    role: $0.window == .session ? .session : .weekly,
                    limit: $0.limit
                )
            }
        ).providerBlockers
        let binding = bindingReading(readings, service: service, isBlocked: !blockers.isEmpty)

        if !policy.allowsEstimatedQuota, binding.limit.isEstimated {
            return reject(
                .estimateNotAllowed,
                "\(subject(candidate)) quota is estimated and \(policy.name) requires a reported total",
                freshness: freshness
            )
        }

        // Exhaustion is judged before the headroom floor so a spent window is
        // named as spent rather than as "below 0%". An estimated window at its
        // limit counts too: the shared blocking policy ignores estimates, but a
        // route must not be recommended on a quota that is very likely gone.
        let exhausted = !blockers.isEmpty
            || readings.contains { $0.limit.isEstimated && $0.percentLeft == 0 }
        if exhausted {
            return reject(
                .quotaExhausted,
                "\(subject(candidate)): \(windowName(binding, service)) quota is spent"
                    + (binding.limit.resetCountdownText(now: context.now).map { ", resets in \($0)" } ?? ""),
                freshness: freshness
            )
        }

        if binding.percentLeft < policy.minimumRemainingPercent {
            return reject(
                .belowMinimumHeadroom,
                "\(subject(candidate)) has \(binding.percentLeft)% \(windowName(binding, service)) quota left; "
                    + "\(policy.name) needs at least \(policy.minimumRemainingPercent)%",
                freshness: freshness
            )
        }

        let pace = binding.limit.pace(now: context.now)
        if let maximumDeficit = policy.maximumDeficitPercent, let pace, pace.deltaPercent > Double(maximumDeficit) {
            return reject(
                .deficitExceedsLimit,
                "\(subject(candidate)) is \(Int(pace.deltaPercent.rounded()))% ahead of sustainable pace; "
                    + "\(policy.name) allows \(maximumDeficit)%",
                freshness: freshness
            )
        }

        if candidate.health == .failing {
            return reject(
                .providerUnhealthy,
                "\(service.displayName) has been failing to refresh, so its quota can't be trusted",
                freshness: freshness
            )
        }

        return .eligible(score(candidate, binding: binding, pace: pace, freshness: freshness, in: context))
    }

    /// Provider-blocking windows only: a model-scoped or code-review allowance
    /// can be spent while the provider itself stays usable, so it must never
    /// decide a route. Present windows are validated before this projection;
    /// only genuinely absent optional windows are omitted.
    private static func windowReadings(of metrics: UsageMetrics) -> [WindowReading] {
        [(ProviderRecommendationWindow.session, metrics.sessionLimit), (.weekly, metrics.weeklyLimit)]
            .compactMap { window, limit in
                guard let limit else {
                    return nil
                }
                return WindowReading(window: window, limit: limit, percentLeft: QuotaMath.percentLeft(for: limit))
            }
    }

    private static func isUsableBlockingLimit(_ limit: UsageLimit) -> Bool {
        limit.total > 0 && limit.total.isFinite && limit.used.isFinite && limit.used >= 0
    }

    /// The window the route is judged on: the tightest, session winning ties —
    /// the provider card's own rule. Cursor's included pools spill into each
    /// other, so while one still has room the roomiest speaks for the provider.
    private static func bindingReading(
        _ readings: [WindowReading],
        service: ServiceType,
        isBlocked: Bool
    ) -> WindowReading {
        let pooled = service == .cursor
            && readings.count >= 2
            && readings.allSatisfy { ServiceType.isCursorIncludedPool(total: $0.limit.total) }
        let useRoomiest = pooled && !isBlocked
        var best = readings[0]
        for reading in readings.dropFirst() {
            let better = useRoomiest
                ? reading.percentLeft > best.percentLeft
                : reading.percentLeft < best.percentLeft
            if better { best = reading }
        }
        return best
    }

    private static func accountScopeViolation(_ candidate: RoutingCandidate, policy: RoutingPolicy) -> String? {
        guard policy.accountSelection == .restricted else { return nil }
        let pinned = policy.accounts.filter { $0.provider == candidate.service }
        guard !pinned.isEmpty else { return nil }
        if let ref = candidate.accountRef, pinned.contains(ref) { return nil }
        return "\(policy.name) is limited to specific \(candidate.service.displayName) accounts"
    }

    // MARK: - Scoring

    private static func score(
        _ candidate: RoutingCandidate,
        binding: WindowReading,
        pace: UsagePace?,
        freshness: RoutingFreshness,
        in context: Context
    ) -> Scored {
        let policy = context.policy
        let service = candidate.service
        let subject = subject(candidate)
        var reasons: [RoutingReason] = []
        var points = Double(binding.percentLeft) * ProviderRecommendationWeights.headroomPointsPerPercentLeft

        reasons.append(RoutingReason(
            code: .quotaHeadroom,
            message: "\(binding.limit.isEstimated ? "~" : "")\(binding.percentLeft)% "
                + "\(windowName(binding, service)) quota remains"
        ))

        let preferenceRank = policy.preferenceRank(of: service)
        if let preferenceRank {
            let table = RoutingWeights.providerPreferencePoints
            points += Double(preferenceRank < table.count ? table[preferenceRank] : 0)
            reasons.append(RoutingReason(
                code: .preferredProvider,
                message: "\(service.displayName) is preferred provider #\(preferenceRank + 1) for \(policy.name)"
            ))
        }

        if policy.accountSelection == .preferred, let ref = candidate.accountRef, policy.accounts.contains(ref) {
            points += RoutingWeights.preferredAccountPoints
            reasons.append(RoutingReason(code: .preferredAccount, message: "\(subject) is a preferred account"))
        }

        if let pace {
            let raw = -pace.deltaPercent * ProviderRecommendationWeights.pacePointsPerDeltaPercent
            let cap = ProviderRecommendationWeights.maximumPaceAdjustment
            points += min(cap, max(-cap, raw))
            switch pace.stage {
            case .reserve:
                reasons.append(RoutingReason(
                    code: .aheadOfPace,
                    message: "\(subject) has \(Int(abs(pace.deltaPercent).rounded()))% in reserve"
                ))
            case .deficit:
                reasons.append(RoutingReason(
                    code: .behindPace,
                    message: "\(subject) is \(Int(abs(pace.deltaPercent).rounded()))% ahead of sustainable pace"
                ))
            case .onPace:
                break
            }
        }

        if let seconds = binding.limit.secondsUntilReset(now: context.now),
           seconds > 0, seconds <= ProviderRecommendationWeights.imminentResetWindow {
            points += ProviderRecommendationWeights.imminentResetBonus
            reasons.append(RoutingReason(
                code: .resetSoon,
                message: "Quota resets in \(UsageDurationText.short(seconds: seconds))"
            ))
        }

        switch RoutingCostClass.of(service) {
        case .included:
            if policy.costPreference != .headroom {
                reasons.append(RoutingReason(code: .includedQuota, message: "Uses included subscription quota"))
            }
        case .metered:
            let penalty = RoutingWeights.meteredPenalty(for: policy.costPreference)
                * RoutingWeights.tierMultiplier(for: policy.modelTier)
            if penalty > 0 {
                points -= penalty
                reasons.append(RoutingReason(
                    code: .meteredUsage,
                    message: "Uses metered credits (cost preference: \(policy.costPreference.rawValue))"
                ))
            }
        }

        if binding.limit.isEstimated {
            reasons.append(RoutingReason(code: .estimatedQuota, message: "Quota total is estimated, not reported"))
        }
        if candidate.health == .degraded {
            points -= RoutingWeights.degradedHealthPenalty
            reasons.append(RoutingReason(
                code: .healthDegraded,
                message: "\(service.displayName) has had recent refresh failures"
            ))
        }

        return Scored(
            candidate: candidate,
            window: binding.window,
            limit: binding.limit,
            percentLeft: binding.percentLeft,
            pace: pace,
            preferenceRank: preferenceRank,
            score: Int(max(0, points).rounded()),
            reasons: reasons,
            freshness: freshness
        )
    }

    // MARK: - Ordering

    /// The step at which two eligible candidates were separated.
    private enum Separation: Equatable {
        case score
        case quotaRemaining
        case policyPreference
        case providerOrder
        case accountOrder
        case accountIdentifier
        case identical

        var isTieBreak: Bool { self != .score && self != .identical }

        var explanation: String {
            switch self {
            case .quotaRemaining: return "more quota remaining"
            case .policyPreference: return "earlier position in your provider preference"
            case .providerOrder: return "MeterBar's provider order"
            case .accountOrder: return "account order"
            case .accountIdentifier: return "account identifier"
            case .score, .identical: return ""
            }
        }
    }

    private struct Ordering {
        let separation: Separation
        let isOrderedBefore: Bool
    }

    private static func ordering(_ lhs: Scored, _ rhs: Scored, policy: RoutingPolicy) -> Ordering {
        if lhs.score != rhs.score {
            return Ordering(separation: .score, isOrderedBefore: lhs.score > rhs.score)
        }
        if lhs.percentLeft != rhs.percentLeft {
            return Ordering(separation: .quotaRemaining, isOrderedBefore: lhs.percentLeft > rhs.percentLeft)
        }
        let lhsRank = lhs.preferenceRank ?? Int.max
        let rhsRank = rhs.preferenceRank ?? Int.max
        if lhsRank != rhsRank {
            return Ordering(separation: .policyPreference, isOrderedBefore: lhsRank < rhsRank)
        }
        return structuralOrdering(lhs.candidate, rhs.candidate)
    }

    private static func structuralOrdering(_ lhs: RoutingCandidate, _ rhs: RoutingCandidate) -> Ordering {
        if lhs.service.sortOrder != rhs.service.sortOrder {
            return Ordering(separation: .providerOrder, isOrderedBefore: lhs.service.sortOrder < rhs.service.sortOrder)
        }
        if lhs.displayOrder != rhs.displayOrder {
            return Ordering(separation: .accountOrder, isOrderedBefore: lhs.displayOrder < rhs.displayOrder)
        }
        let lhsID = lhs.accountID?.uuidString ?? ""
        let rhsID = rhs.accountID?.uuidString ?? ""
        if lhsID != rhsID {
            return Ordering(separation: .accountIdentifier, isOrderedBefore: lhsID < rhsID)
        }
        return Ordering(separation: .identical, isOrderedBefore: false)
    }

    private static func canonicalOrder(_ lhs: RoutingCandidate, _ rhs: RoutingCandidate) -> Bool {
        structuralOrdering(lhs, rhs).isOrderedBefore
    }

    /// Everything after the recommendation, in the policy's fallback order and
    /// capped at its fallback count.
    private static func fallbackChain(_ ranked: [Scored], policy: RoutingPolicy) -> [Scored] {
        var rest = Array(ranked.dropFirst())
        if policy.fallbackOrder == .policyPreference {
            rest.sort { lhs, rhs in
                let lhsRank = lhs.preferenceRank ?? Int.max
                let rhsRank = rhs.preferenceRank ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return ordering(lhs, rhs, policy: policy).isOrderedBefore
            }
        }
        return Array(rest.prefix(policy.maximumFallbacks))
    }

    // MARK: - Decision

    private static func decision(
        ranked: [Scored],
        chain: [Scored],
        rejections: [RoutingRejection],
        context: Context
    ) -> RoutingDecision {
        let policy = context.policy
        let task = RoutingTaskSummary(policy: policy)

        guard let top = ranked.first else {
            let outcome: RoutingOutcome = rejections.allSatisfy(\.code.isDataProblem)
                ? .dataUnavailable
                : .noEligibleCandidate
            let reasons = rejections.isEmpty
                ? [RoutingReason(code: .noCandidates, message: "No provider or account is set up to route to")]
                : []
            return RoutingDecision(
                outcome: outcome,
                evaluatedAt: context.now,
                task: task,
                recommendation: nil,
                fallbacks: [],
                rejected: rejections,
                reasons: reasons,
                summary: outcome == .dataUnavailable
                    ? "No fresh quota data is available to route \(policy.name)."
                    : "No eligible route for \(policy.name): every candidate was rejected."
            )
        }

        var notes: [RoutingReason] = []
        if ranked.count == 1 {
            notes.append(RoutingReason(
                code: .onlyEligibleCandidate,
                message: "\(subject(top.candidate)) is the only eligible candidate"
            ))
        } else {
            let separation = ordering(ranked[0], ranked[1], policy: policy).separation
            if separation.isTieBreak {
                notes.append(RoutingReason(
                    code: .tieBreakApplied,
                    message: "Scores tied at \(top.score); chose \(subject(top.candidate)) by \(separation.explanation)"
                ))
            }
        }

        let route = makeRoute(top, rank: 1, policy: policy)
        return RoutingDecision(
            outcome: .recommended,
            evaluatedAt: context.now,
            task: task,
            recommendation: route,
            fallbacks: chain.enumerated().map { makeRoute($1, rank: $0 + 2, policy: policy) },
            rejected: rejections,
            reasons: notes,
            summary: "Use \(routeLabel(route, policy: policy))"
        )
    }

    private static func makeRoute(_ entry: Scored, rank: Int, policy: RoutingPolicy) -> RoutingRoute {
        let service = entry.candidate.service
        return RoutingRoute(
            rank: rank,
            provider: service.cliIdentifier,
            providerName: service.displayName,
            account: entry.candidate.accountSummary,
            model: RoutingModelSelection(tier: policy.modelTier, alias: policy.modelAliases[service]),
            score: entry.score,
            quota: RoutingQuotaSummary(
                window: entry.window.rawValue,
                periodKind: entry.limit.periodKind?.rawValue,
                percentLeft: entry.percentLeft,
                quotaBand: QuotaBand.forPercentLeft(entry.percentLeft).cliIdentifier,
                estimated: entry.limit.isEstimated,
                resetAt: entry.limit.resetTime,
                pace: entry.pace.map(RoutingPaceSummary.init(pace:))
            ),
            freshness: entry.freshness,
            reasons: entry.reasons
        )
    }

    /// "Codex · Work · standard model" — the line the epic promises.
    public static func routeLabel(_ route: RoutingRoute, policy: RoutingPolicy) -> String {
        let provider = route.service?.shortName ?? route.providerName
        let model = route.model.alias ?? "\(route.model.tier) model"
        return [provider, route.account?.label, model].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Wording

    private static func subject(_ candidate: RoutingCandidate) -> String {
        guard let account = candidate.accountSummary else { return candidate.service.displayName }
        return "\(candidate.service.displayName) (\(account.label))"
    }

    /// The window's display title, lowercased only when it is a plain cadence
    /// word ("weekly quota"). A provider-specific pool name keeps its capitals
    /// ("Cursor Models quota") rather than reading as "cursor models quota".
    private static func windowName(_ reading: WindowReading, _ service: ServiceType) -> String {
        let title = reading.window.title(
            for: service,
            limitTotal: reading.limit.total,
            periodKind: reading.limit.periodKind
        )
        let cadenceWords: Set<String> = ["Session", "Weekly", "Monthly", "Daily", "Billing cycle", "Quota"]
        return cadenceWords.contains(title) ? title.lowercased() : title
    }
}
