import Foundation

/// One provider or account the recommendation considers.
///
/// The candidate carries only the two provider-blocking windows because those
/// are the ones that stop work: a model-scoped or code-review window can be
/// spent while the provider itself stays perfectly usable, so ranking on it
/// would recommend against a tool that is in fact free. `lastUpdated` is
/// `nil` when no snapshot has ever been cached for this provider, which is
/// what separates "never fetched" from "fetched but empty".
public struct ProviderRecommendationCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let service: ServiceType
    /// Position of this account within its provider, so multi-account
    /// providers keep the order the rest of the app shows them in.
    public let displayOrder: Int
    public let sessionLimit: UsageLimit?
    public let weeklyLimit: UsageLimit?
    public let lastUpdated: Date?
    /// Set when the caller already knows the provider is unusable for a reason
    /// the planner cannot see in the numbers — a signed-out account, say, whose
    /// last cached reading is fresh and healthy but no longer reachable. It
    /// short-circuits ranking so those percentages never become a suggestion.
    public let unavailableReason: ProviderRecommendationUnavailability?

    public init(
        id: String,
        name: String,
        service: ServiceType,
        displayOrder: Int,
        sessionLimit: UsageLimit?,
        weeklyLimit: UsageLimit?,
        lastUpdated: Date?,
        unavailableReason: ProviderRecommendationUnavailability? = nil
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.displayOrder = displayOrder
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.lastUpdated = lastUpdated
        self.unavailableReason = unavailableReason
    }

    /// Convenience for callers that already hold a cached snapshot. Drops the
    /// model-scoped window on purpose — see the type's note.
    public init(
        id: String,
        name: String,
        service: ServiceType,
        displayOrder: Int,
        metrics: UsageMetrics?,
        unavailableReason: ProviderRecommendationUnavailability? = nil
    ) {
        self.init(
            id: id,
            name: name,
            service: service,
            displayOrder: displayOrder,
            sessionLimit: metrics?.sessionLimit,
            weeklyLimit: metrics?.weeklyLimit,
            lastUpdated: metrics?.lastUpdated,
            unavailableReason: unavailableReason
        )
    }
}

/// The provider-blocking window a recommendation row is constrained by.
///
/// Deliberately narrower than `WidgetQuotaWindow`, which also carries
/// `codeReview`: that window never blocks a provider, so it can never be the
/// reason to pick a different tool.
public enum ProviderRecommendationWindow: String, Equatable, Sendable {
    case session
    case weekly

    public func title(for service: ServiceType) -> String {
        switch (self, service) {
        case (.session, .openRouter):
            return "Key limit"
        case (.session, _):
            return "Session"
        case (.weekly, _):
            return service.weeklyQuotaTitle
        }
    }
}

/// Why a candidate could not be ranked. Every case is a statement about the
/// cache, never an estimate of the quota behind it — a provider MeterBar
/// cannot currently measure is listed, not guessed at.
public enum ProviderRecommendationUnavailability: Equatable, Sendable {
    /// No usage has ever been cached for this provider or account.
    case noSnapshot
    /// A snapshot exists but reports no usable session or weekly window.
    case noBindingWindow
    /// The snapshot is older than the staleness threshold.
    case stale(age: TimeInterval)
    /// The caller knows the provider is unusable for a reason outside the
    /// numbers — signed out, not connected, needs attention — and supplies the
    /// wording, so provider auth vocabulary stays out of the shared planner.
    case blocked(String)

    public var detail: String {
        switch self {
        case .noSnapshot:
            return "No usage cached yet"
        case .noBindingWindow:
            return "No session or weekly window reported"
        case let .stale(age):
            return "Last updated \(UsageDurationText.short(seconds: age)) ago"
        case let .blocked(detail):
            return detail
        }
    }
}

/// A ranked provider, carrying every input that produced its score so the row
/// can show its own reasoning rather than assert a verdict.
public struct ProviderRecommendationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let service: ServiceType
    public let window: ProviderRecommendationWindow
    public let limit: UsageLimit
    public let percentLeft: Int
    public let band: QuotaBand
    public let secondsUntilReset: TimeInterval?
    public let pace: UsagePace?
    public let score: Int

    public var isExhausted: Bool {
        band == .exhausted
    }

    public var windowTitle: String {
        window.title(for: service)
    }

    public var headroomText: String {
        limit.percentLeftText
    }

    /// "Resets in 3h 20m" — or "Resets now" once the countdown has run out but
    /// the provider has not yet reported the refill.
    public var resetText: String? {
        guard let secondsUntilReset else { return nil }
        guard secondsUntilReset > 0 else { return "Resets now" }
        return "Resets in \(UsageDurationText.short(seconds: secondsUntilReset))"
    }

    public var paceText: String? {
        pace?.leftLabel
    }

    /// When this provider becomes usable again. Only meaningful for a spent
    /// window, and `nil` when the provider reports no reset time — the row says
    /// nothing rather than inventing a return.
    public var availabilityText: String? {
        guard isExhausted, let secondsUntilReset else { return nil }
        guard secondsUntilReset > 0 else { return "Available now" }
        return "Available in \(UsageDurationText.short(seconds: secondsUntilReset))"
    }

    /// One-line form for compact surfaces (the popover hint).
    public var summary: String {
        if isExhausted {
            let suffix = availabilityText.map { ", \($0.lowercased())" } ?? ""
            return "\(name) — out of \(windowTitle.lowercased()) quota\(suffix)"
        }
        let suffix = resetText.map { ", \($0.lowercased())" } ?? ""
        return "\(name) — \(headroomText) on \(windowTitle)\(suffix)"
    }
}

public struct ProviderRecommendationUnavailableRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let service: ServiceType
    public let reason: ProviderRecommendationUnavailability

    public var detail: String {
        reason.detail
    }
}

public struct ProviderRecommendation: Equatable, Sendable {
    /// Rankable providers, best headroom first, spent windows last.
    public let rows: [ProviderRecommendationRow]
    /// Providers deliberately left out of the ranking, with the reason.
    public let unavailable: [ProviderRecommendationUnavailableRow]

    public var top: ProviderRecommendationRow? {
        rows.first
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }

    /// True when every rankable provider is spent — the case where the honest
    /// answer is "none of them, and here is when the first one returns".
    public var isFullyExhausted: Bool {
        !rows.isEmpty && rows.allSatisfy(\.isExhausted)
    }

    /// The one-line answer, shared by the dashboard card's lead and the popover
    /// hint so the two surfaces cannot phrase the same ranking differently.
    /// `nil` when nothing is rankable — no headline is better than a hedge.
    public var headline: String? {
        guard let top else { return nil }
        if isFullyExhausted {
            let availability = top.availabilityText.map { ", \($0.lowercased())" } ?? ""
            return "Every window is spent — \(top.name) is back first\(availability)"
        }
        let reset = top.resetText.map { ", \($0.lowercased())" } ?? ""
        return "Use \(top.name) next — \(top.headroomText) on \(top.windowTitle.lowercased())\(reset)"
    }
}

/// Weights for the headroom score, in score points.
///
/// The score answers one question — "how much room does this provider have
/// left right now?" — so percent-left is the base and everything else is a
/// bounded adjustment on top of it. Keeping the weights named and capped is
/// what makes a row's ordering explainable from the values the row already
/// shows; a bare tuned constant would not be.
public enum ProviderRecommendationWeights {
    /// Each percentage point left of the binding window is worth one point, so
    /// an unadjusted score reads as "percent left".
    public static let headroomPointsPerPercentLeft = 1.0

    /// How much one point of pace delta moves the score. Burning slower than
    /// the window elapses (reserve) adds; burning faster (deficit) subtracts.
    public static let pacePointsPerDeltaPercent = 0.4

    /// Ceiling on the pace adjustment in either direction. Pace is a
    /// short-horizon projection off a partially elapsed window, so it may
    /// nudge the order but must never out-vote the headroom it is measured
    /// against — twelve points cannot flip a provider past one with a quarter
    /// more quota left.
    public static let maximumPaceAdjustment = 12.0

    /// Bonus for a window that refills within `imminentResetWindow`. A quota
    /// that is about to be replaced is worth more than its current percentage
    /// suggests, but only slightly — it is still spent until it resets.
    public static let imminentResetBonus = 4.0

    /// How soon a reset has to be to earn `imminentResetBonus`.
    public static let imminentResetWindow: TimeInterval = 30 * 60
}

/// Pure ranking policy for "which provider should I use next?".
///
/// The planner reads no global state and owns no clock: `now` is injected and
/// every input comes from snapshots the app has already cached, so the answer
/// is deterministic and directly testable — and so this makes no network
/// requests and collects nothing new. Callers decide *which* providers are
/// eligible (hidden providers simply never become candidates); the planner
/// only orders what it is given and says why.
public enum ProviderRecommendationPlanner {
    /// Matches the widget's staleness precedent: past two hours a snapshot
    /// describes a quota window that has likely moved on.
    public static let defaultStalenessThreshold: TimeInterval = 2 * 60 * 60

    public static func rank(
        candidates: [ProviderRecommendationCandidate],
        now: Date,
        stalenessThreshold: TimeInterval = defaultStalenessThreshold
    ) -> ProviderRecommendation {
        var rows: [ProviderRecommendationRow] = []
        var unavailable: [ProviderRecommendationUnavailableRow] = []

        for candidate in candidates.sorted(by: { order($0) < order($1) }) {
            switch evaluate(candidate: candidate, now: now, stalenessThreshold: stalenessThreshold) {
            case let .ranked(row):
                rows.append(row)
            case let .unavailable(reason):
                unavailable.append(
                    ProviderRecommendationUnavailableRow(
                        id: candidate.id,
                        name: candidate.name,
                        service: candidate.service,
                        reason: reason
                    )
                )
            }
        }

        return ProviderRecommendation(rows: sorted(rows, candidates: candidates), unavailable: unavailable)
    }

    // MARK: - Evaluation

    private enum Evaluation {
        case ranked(ProviderRecommendationRow)
        case unavailable(ProviderRecommendationUnavailability)
    }

    private static func evaluate(
        candidate: ProviderRecommendationCandidate,
        now: Date,
        stalenessThreshold: TimeInterval
    ) -> Evaluation {
        if let unavailableReason = candidate.unavailableReason {
            return .unavailable(unavailableReason)
        }

        guard let lastUpdated = candidate.lastUpdated else {
            return .unavailable(.noSnapshot)
        }

        let age = now.timeIntervalSince(lastUpdated)
        guard age <= stalenessThreshold else {
            return .unavailable(.stale(age: age))
        }

        guard let binding = bindingWindow(for: candidate) else {
            return .unavailable(.noBindingWindow)
        }

        let percentLeft = QuotaMath.percentLeft(for: binding.limit)
        let band = QuotaBand.forPercentLeft(percentLeft)
        let secondsUntilReset = binding.limit.secondsUntilReset(now: now)
        let pace = binding.limit.pace(now: now)

        return .ranked(
            ProviderRecommendationRow(
                id: candidate.id,
                name: candidate.name,
                service: candidate.service,
                window: binding.window,
                limit: binding.limit,
                percentLeft: percentLeft,
                band: band,
                secondsUntilReset: secondsUntilReset,
                pace: pace,
                score: band == .exhausted
                    ? 0
                    : score(percentLeft: percentLeft, pace: pace, secondsUntilReset: secondsUntilReset)
            )
        )
    }

    /// The tightest window that can block the provider. Ties keep the session
    /// window, matching the provider card's own primary-limit rule so the
    /// recommendation never explains itself with a different number than the
    /// card beside it.
    private static func bindingWindow(
        for candidate: ProviderRecommendationCandidate
    ) -> (window: ProviderRecommendationWindow, limit: UsageLimit)? {
        let windows: [(ProviderRecommendationWindow, UsageLimit)] = [
            (.session, candidate.sessionLimit),
            (.weekly, candidate.weeklyLimit)
        ].compactMap { window, limit in
            // A zero total carries no headroom information — reading it as
            // "100% left" would recommend a provider MeterBar cannot measure.
            guard let limit, limit.total > 0 else { return nil }
            return (window, limit)
        }

        return windows.min { QuotaMath.percentLeft(for: $0.1) < QuotaMath.percentLeft(for: $1.1) }
    }

    private static func score(
        percentLeft: Int,
        pace: UsagePace?,
        secondsUntilReset: TimeInterval?
    ) -> Int {
        let headroom = Double(percentLeft) * ProviderRecommendationWeights.headroomPointsPerPercentLeft

        // `deltaPercent` is positive when the provider is *behind* on quota, so
        // negating it turns a reserve into a bonus and a deficit into a penalty.
        let paceAdjustment = pace.map { pace -> Double in
            let raw = -pace.deltaPercent * ProviderRecommendationWeights.pacePointsPerDeltaPercent
            return min(
                ProviderRecommendationWeights.maximumPaceAdjustment,
                max(-ProviderRecommendationWeights.maximumPaceAdjustment, raw)
            )
        } ?? 0

        let resetBonus: Double
        if let secondsUntilReset,
           secondsUntilReset > 0,
           secondsUntilReset <= ProviderRecommendationWeights.imminentResetWindow {
            resetBonus = ProviderRecommendationWeights.imminentResetBonus
        } else {
            resetBonus = 0
        }

        return Int(max(0, headroom + paceAdjustment + resetBonus).rounded())
    }

    // MARK: - Ordering

    private static func sorted(
        _ rows: [ProviderRecommendationRow],
        candidates: [ProviderRecommendationCandidate]
    ) -> [ProviderRecommendationRow] {
        let orderByID = Dictionary(
            candidates.map { ($0.id, order($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let fallback = (Int.max, Int.max, "")

        return rows.sorted { lhs, rhs in
            // A spent window is never a recommendation, however soon it refills.
            if lhs.isExhausted != rhs.isExhausted {
                return rhs.isExhausted
            }

            if lhs.isExhausted {
                // Among spent providers the only useful ordering is which one
                // comes back first; an unknown reset sorts last.
                let lhsReset = lhs.secondsUntilReset ?? .greatestFiniteMagnitude
                let rhsReset = rhs.secondsUntilReset ?? .greatestFiniteMagnitude
                if lhsReset != rhsReset {
                    return lhsReset < rhsReset
                }
            } else {
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.percentLeft != rhs.percentLeft {
                    return lhs.percentLeft > rhs.percentLeft
                }
            }

            return orderByID[lhs.id, default: fallback] < orderByID[rhs.id, default: fallback]
        }
    }

    private static func order(_ candidate: ProviderRecommendationCandidate) -> (Int, Int, String) {
        (candidate.service.sortOrder, candidate.displayOrder, candidate.id)
    }
}
