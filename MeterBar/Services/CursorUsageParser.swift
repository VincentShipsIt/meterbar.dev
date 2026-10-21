import Foundation
import MeterBarShared

/// Pure Cursor payload decoding and quota mapping; no credentials or I/O.
nonisolated enum CursorUsageParser {
    // Last-resort monthly request quota, used only when the API returns no
    // usable plan quota at all; the resulting limit is marked `isEstimated`.
    // Static so the pure `mapSummary` mapping can share the same constant.
    private static let defaultPlanTotal: Double = 500

    // Display headroom estimate when no explicit on-demand limit is returned by the API
    private static let onDemandHeadroomMultiplier: Double = 1.5

    static func summary(from data: Data) throws -> CursorUsageSummaryResponse {
        try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
    }

    static func sandStatus(from data: Data) throws -> CursorSandUsageStatusResponse {
        try JSONDecoder().decode(CursorSandUsageStatusResponse.self, from: data)
    }

    static func planInfo(from data: Data) throws -> CursorPlanInfoResponse {
        try JSONDecoder().decode(CursorPlanInfoResponse.self, from: data)
    }

    /// One poll's reading of the plan counter, in requests.
    ///
    /// `.requests`, never `.usd`: `/api/usage-summary` publishes no currency
    /// field — `plan.used`, `plan.limit` and the on-demand figures are integer
    /// counts against a plan allowance, and Cursor publishes no per-request rate
    /// anywhere MeterBar can read. Any dollar figure derived here would be
    /// invented, so this counter is barred from `costs[]` by
    /// `ProviderUsageLedger.dailyUSDSeries(for:)` and surfaces as a request
    /// series instead.
    ///
    /// Two-pool percent payloads (`autoPercentUsed` / `apiPercentUsed`) are the
    /// dashboard's included-usage bars, not a running request counter.
    /// Differencing `plan.used` across that shape change produced a phantom
    /// multi-thousand "request" spike, so those payloads yield no observation.
    ///
    /// On-demand usage is billed and counted separately, so it is deliberately
    /// not summed in: the total would then be in neither unit. No token counts
    /// ride along either — the endpoint reports none.
    ///
    /// The counter zeroes at `billingCycleStart`; the ledger reads a drop as a
    /// reset rather than a negative delta, so no cycle rollover emits a negative
    /// day.
    ///
    /// Returns `nil` when the payload carries no plan counter at all. Defaulting
    /// the absent field to `0` would be indistinguishable from a real reset to
    /// the ledger, which reads a drop as a new billing cycle and re-baselines to
    /// zero — so the next complete poll would charge the entire cycle-to-date
    /// count to a single day as a phantom spike.
    static func observation(
        _ summaryData: CursorUsageSummaryResponse,
        at observedAt: Date
    ) -> ProviderUsageObservation? {
        let plan = selectedUsage(from: summaryData).plan
        if plan?.autoPercentUsed != nil, plan?.apiPercentUsed != nil {
            return nil
        }
        guard let used = plan?.used else { return nil }
        return ProviderUsageObservation(
            provider: .xai,
            unit: .requests,
            runningTotal: Double(used),
            // Cursor publishes no per-day figure, so there is nothing
            // authoritative to prefer over the poll-to-poll delta.
            authoritativeDailyTotal: nil,
            // Deltas are dated when MeterBar observed them, so the user's own
            // calendar is the right one.
            dayBoundary: .local,
            observedAt: observedAt
        )
    }

    /// Maps a decoded Cursor usage-summary response onto the shared
    /// `UsageMetrics` shape under the single xAI provider. Pure and
    /// side-effect-free so it can be fixture-tested without the network or
    /// Cursor's SQLite DB.
    ///
    /// xAI plans share one weekly pool across Grok and Cursor, so the weekly
    /// slot (`weeklyLimit`) carries that pool when the account has it: the
    /// sand status pool wins, and a merged weekly plan with no mappable sand
    /// pool falls back to the usage-summary bars on the weekly reset. The
    /// merger prefers Grok's own read of the same pool when it has one.
    ///
    /// Legacy accounts still on monthly Cursor pools list them as labelled
    /// `additionalLimits` rows ("Cursor Models" from `plan.autoPercentUsed`,
    /// "Other Models" from `plan.apiPercentUsed`); without a weekly pool the
    /// roomiest one (or the request-count quota of a legacy plan) is also the
    /// `weeklyLimit` headline gauge, titled "Monthly". Enabled on-demand spend
    /// is `codeReviewLimit`, titled "On-demand".
    ///
    /// The plan denominator for the request-count shape comes from the server
    /// (`plan.limit`, else `plan.breakdown`, else the legacy flat
    /// `plan.total`); only when none is present is the assumed quota
    /// substituted and flagged `isEstimated`.
    static func metrics(
        _ summaryData: CursorUsageSummaryResponse,
        sandStatus: CursorSandUsageStatusResponse? = nil,
        planInfo: CursorPlanInfoResponse? = nil,
        now: Date = Date()
    ) -> UsageMetrics {
        let cycle = billingCycle(from: summaryData)

        let usage = selectedUsage(from: summaryData)
        let plan = usage.plan
        let sandLimit = mapSandUsage(sandStatus)
        let onDemand = onDemandLimit(
            from: usage.onDemand,
            resetTime: cycle.resetTime,
            windowSeconds: cycle.windowSeconds
        )
        let weeklyIncluded = planInfo?.planInfo?.isWeeklyIncluded == true
        let unified = weeklyIncluded || sandStatus?.isUnified == true

        if let autoPercent = plan?.autoPercentUsed, let apiPercent = plan?.apiPercentUsed {
            if unified, let sandLimit {
                return UsageMetrics(service: .xai, weeklyLimit: sandLimit, codeReviewLimit: onDemand, lastUpdated: now)
            }
            let included = includedUsageWindow(
                billing: cycle,
                planInfo: planInfo,
                useWeeklyReset: weeklyIncluded
            )
            if weeklyIncluded {
                // A weekly plan whose sand pool did not map: the summary bars
                // are the best read of the shared pool. The binding (higher)
                // percent stands for it, so one weekly gauge is drawn.
                let pools = [autoPercent, apiPercent].compactMap(plausiblePercent)
                let weekly = pools.max().flatMap {
                    percentPoolLimit(
                        $0,
                        resetTime: included.resetTime,
                        windowSeconds: included.windowSeconds,
                        periodKind: .weekly
                    )
                }
                return UsageMetrics(
                    service: .xai,
                    weeklyLimit: weekly ?? sandLimit,
                    codeReviewLimit: onDemand,
                    lastUpdated: now
                )
            }
            let autoPool = percentPoolLimit(
                autoPercent,
                resetTime: included.resetTime,
                windowSeconds: included.windowSeconds,
                periodKind: included.periodKind,
                label: ServiceType.legacyCursorModelsLabel
            )
            let apiPool = percentPoolLimit(
                apiPercent,
                resetTime: included.resetTime,
                windowSeconds: included.windowSeconds,
                periodKind: included.periodKind,
                label: ServiceType.legacyOtherModelsLabel
            )
            // An account with no weekly pool still needs a headline gauge for
            // the menu bar and widget. Cursor's included pools spill into each
            // other, so the roomiest one stands for the account: emptying one
            // while the other has headroom is not "out".
            let binding = [autoPool, apiPool].compactMap { $0 }.min { $0.used < $1.used }
            return UsageMetrics(
                service: .xai,
                weeklyLimit: sandLimit ?? binding.map(Self.unlabelled),
                codeReviewLimit: onDemand,
                additionalLimits: [autoPool, apiPool].compactMap { $0 },
                lastUpdated: now
            )
        }

        guard let usedCount = plan?.used else {
            // Missing counter: zero is not unknown. `observation()` above refuses
            // this exact shape for the same reason — a renamed or dropped `used`
            // field (even one that still carries `limit`/`serverQuota`) must not
            // render as a confident "0 used" gauge. Report no included window at
            // all rather than invent one.
            return UsageMetrics(service: .xai, weeklyLimit: sandLimit, codeReviewLimit: onDemand, lastUpdated: now)
        }

        let planUsed = Double(usedCount)
        let serverQuota = plan?.serverQuota
        let planTotalIsEstimated = serverQuota == nil
        let planTotal = Double(serverQuota ?? Int(defaultPlanTotal))

        // Billing-cycle request quota of a legacy plan. Its cadence is the
        // invoice cycle, so it carries the monthly period kind. It is the
        // headline gauge unless the weekly pool exists, in which case it rides
        // as an extra row.
        let requestQuota = UsageLimit(
            used: planUsed,
            total: planTotal,
            resetTime: cycle.resetTime,
            windowSeconds: cycle.windowSeconds,
            isEstimated: planTotalIsEstimated,
            periodKind: .monthly
        )
        return UsageMetrics(
            service: .xai,
            weeklyLimit: sandLimit ?? requestQuota,
            codeReviewLimit: onDemand,
            additionalLimits: sandLimit == nil ? [] : [requestQuota],
            lastUpdated: now
        )
    }

    private static func unlabelled(_ limit: UsageLimit) -> UsageLimit {
        UsageLimit(
            used: limit.used,
            total: limit.total,
            resetTime: limit.resetTime,
            windowSeconds: limit.windowSeconds,
            isEstimated: limit.isEstimated,
            periodKind: limit.periodKind
        )
    }

    /// A dashboard percent is only plausible in `0...100`. This is deliberately
    /// conservative hardening, not a fix for an observed break: it catches an
    /// obviously-wrong shape (negative, `NaN`, or a value that overshot 100 —
    /// e.g. a units mixup), but a payload that switched to a 0-to-1 fraction
    /// (`0.85` meaning 85%) numerically survives this check like any small,
    /// legitimately-low percent would, and still renders wrong. See PR notes.
    private static func plausiblePercent(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }

    /// The weekly pool Cursor's sand status reports. Follows Grok Bot.app's omit
    /// rules plus MeterBar's "no phantom 0% bar without a grant" rule.
    static func mapSandUsage(_ status: CursorSandUsageStatusResponse?) -> UsageLimit? {
        guard let status else { return nil }
        guard let used = status.usagePercent.flatMap(plausiblePercent) else {
            return nil
        }
        if status.usesPooledEnterpriseAllowance == true {
            return nil
        }
        if status.hasNonZeroIncludedLimit == false, used <= 0 {
            return nil
        }

        let start = status.currentPeriodStart.flatMap(FlexibleISO8601.date(from:))
        let end = status.nextResetTimestampUtc.flatMap(FlexibleISO8601.date(from:))
        let windowSeconds: TimeInterval?
        if let start, let end {
            let duration = end.timeIntervalSince(start)
            windowSeconds = duration > 0 ? duration : nil
        } else {
            windowSeconds = nil
        }

        return UsageLimit(
            used: used,
            total: ServiceType.xaiPercentPoolTotal,
            resetTime: end,
            windowSeconds: windowSeconds,
            isEstimated: false,
            periodKind: .weekly
        )
    }

    /// `billingCycleEnd` is the reset. `end − start` is the real cycle length
    /// when both parse and the duration is positive — no assumed 30-day month.
    private static func billingCycle(
        from summary: CursorUsageSummaryResponse
    ) -> (resetTime: Date?, windowSeconds: TimeInterval?) {
        let start = summary.billingCycleStart.flatMap(FlexibleISO8601.date(from:))
        let end = summary.billingCycleEnd.flatMap(FlexibleISO8601.date(from:))
        let windowSeconds: TimeInterval?
        if let start, let end {
            let duration = end.timeIntervalSince(start)
            windowSeconds = duration > 0 ? duration : nil
        } else {
            windowSeconds = nil
        }
        return (end, windowSeconds)
    }

    /// Invoice cycle for an unmerged account. A weekly included plan moves the
    /// reset to `includedUsageResetsAt` and does not invent a window length.
    private static func includedUsageWindow(
        billing: (resetTime: Date?, windowSeconds: TimeInterval?),
        planInfo: CursorPlanInfoResponse?,
        useWeeklyReset: Bool
    ) -> (resetTime: Date?, windowSeconds: TimeInterval?, periodKind: UsageLimit.PeriodKind) {
        guard useWeeklyReset else {
            return (billing.resetTime, billing.windowSeconds, .monthly)
        }
        return (planInfo?.planInfo?.includedUsageResetsAt, nil, .weekly)
    }

    /// `GetPlanInfo.planName` ("Ultra") wins over usage-summary `membershipType`
    /// ("unified_ultra"). An empty name leaves the summary token in place.
    static func membershipType(
        summary: String?,
        planInfo: CursorPlanInfoResponse?
    ) -> String? {
        if let name = planInfo?.planInfo?.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return summary
    }

    /// One included pool as the dashboard draws it: `used` is already a
    /// 0…100 percent, so the denominator is 100 rather than a request grant.
    /// Unmerged pools reset with the billing cycle (`.monthly`). A weekly
    /// included plan uses `.weekly` so the row titles Weekly. Returns `nil`
    /// — rather than a plausible-looking clamped gauge — when `percentUsed`
    /// fails the `plausiblePercent` range check.
    private static func percentPoolLimit(
        _ percentUsed: Double,
        resetTime: Date?,
        windowSeconds: TimeInterval?,
        periodKind: UsageLimit.PeriodKind,
        label: String? = nil
    ) -> UsageLimit? {
        guard let used = plausiblePercent(percentUsed) else { return nil }
        return UsageLimit(
            used: used,
            total: ServiceType.xaiPercentPoolTotal,
            resetTime: resetTime,
            windowSeconds: windowSeconds,
            isEstimated: false,
            periodKind: periodKind,
            label: label
        )
    }

    private static func onDemandLimit(
        from onDemand: CursorOnDemandUsage?,
        resetTime: Date?,
        windowSeconds: TimeInterval?
    ) -> UsageLimit? {
        guard let onDemand, onDemand.enabled == true else { return nil }
        let onDemandUsed = Double(onDemand.used ?? 0)
        let onDemandLimit = Double(onDemand.limit ?? 0)
        guard onDemandUsed > 0 || onDemandLimit > 0 else { return nil }
        return UsageLimit(
            used: onDemandUsed,
            total: onDemandLimit > 0 ? onDemandLimit : onDemandUsed * onDemandHeadroomMultiplier,
            resetTime: resetTime,
            windowSeconds: windowSeconds,
            isEstimated: onDemandLimit <= 0
        )
    }

    /// Resolves the two response shapes once so plan and on-demand usage cannot
    /// come from different accounts. An explicit individual counter wins even
    /// when it is zero; team usage is selected only when individual usage has no
    /// counter. If neither has a counter, retain a server-backed quota or the
    /// first available shape for the summary mapper, while `observation` still
    /// rejects the missing counter instead of inventing a reset.
    private static func selectedUsage(
        from summaryData: CursorUsageSummaryResponse
    ) -> (plan: CursorPlanUsage?, onDemand: CursorOnDemandUsage?) {
        let individual = summaryData.individualUsage
        let team = summaryData.teamUsage

        if individual?.plan?.used != nil {
            return (individual?.plan, individual?.onDemand)
        }
        if team?.plan?.used != nil {
            return (team?.plan, team?.onDemand)
        }
        if individual?.plan?.serverQuota != nil {
            return (individual?.plan, individual?.onDemand)
        }
        if team?.plan?.serverQuota != nil {
            return (team?.plan, team?.onDemand)
        }
        if individual != nil {
            return (individual?.plan, individual?.onDemand)
        }
        return (team?.plan, team?.onDemand)
    }
}

// MARK: - Response Models

/// Response from https://cursor.com/api/usage-summary
/// Based on Vibeviewer implementation
nonisolated struct CursorUsageSummaryResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let individualUsage: CursorIndividualUsage?
    let teamUsage: CursorTeamUsage?
}

nonisolated struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

nonisolated struct CursorPlanUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    /// Current shape: the grant is nested under `breakdown`.
    let breakdown: CursorPlanBreakdown?
    /// Legacy shape: `included`/`bonus`/`total` were flat plan properties.
    /// Kept so older payloads (and cached responses) still yield a quota.
    let included: Int?
    let bonus: Int?
    let total: Int?
    /// Included **Cursor Models** pool, 0…100, as the dashboard's first bar.
    let autoPercentUsed: Double?
    /// Included **Other Models** (API) pool, 0…100, as the dashboard's second bar.
    let apiPercentUsed: Double?
    /// Combined included-usage percent. Not mapped — the dashboard draws the
    /// two pools separately, and folding them into one bar is what made MeterBar
    /// disagree with Cursor's own UI.
    let totalPercentUsed: Double?

    /// Quota the dashboard divides by, in precedence order: the enforced
    /// `limit`, then the nested grant, then the legacy flat `total`. Returns
    /// nil when the server sends no usable denominator (absent or zeroed), so
    /// callers can flag the substituted value as estimated instead of silently
    /// presenting a guess as fact.
    var serverQuota: Int? {
        [limit, breakdown?.grantTotal, total]
            .compactMap { $0 }
            .first { $0 > 0 }
    }
}

/// Nested plan grant: `included` is the subscription allowance and `bonus` any
/// promotional top-up, with `total` their sum.
nonisolated struct CursorPlanBreakdown: Decodable {
    let included: Int?
    let bonus: Int?
    let total: Int?

    /// `total` when present, otherwise the sum of its parts — a payload that
    /// only itemizes the grant still carries a real server quota.
    var grantTotal: Int? {
        if let total, total > 0 { return total }
        // Non-positive parts are absent grants, not debits — summing them would
        // shrink the denominator below what the server actually granted.
        let parts = [included, bonus].compactMap { $0 }.filter { $0 > 0 }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +)
    }
}

nonisolated struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let enabled: Bool?
}

nonisolated struct CursorTeamUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

/// Response from `POST …/DashboardService/GetSandUsageStatus`.
/// Weekly included pool. `isUnified` marks the shared Cursor / SpaceXAI / X
/// allowance. Live keys are camelCase. Unknown keys are ignored.
nonisolated struct CursorSandUsageStatusResponse: Decodable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasAvailableUsage: Bool?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let availableBankedResetCount: Int?
    let usesPooledEnterpriseAllowance: Bool?
    let isUnified: Bool?
}

/// Response from `POST …/DashboardService/GetPlanInfo`.
/// Connect JSON stringifies int64, so the reset instant arrives as a string
/// of epoch milliseconds. `billingCycleEnd` on this payload is the invoice,
/// not the included-usage reset.
nonisolated struct CursorPlanInfoResponse: Decodable {
    let planInfo: Info?
    let isMerged: Bool?

    nonisolated struct Info: Decodable {
        let planName: String?
        let includedUsagePeriod: String?
        let includedUsageResetsAt: Date?

        var isWeeklyIncluded: Bool {
            includedUsagePeriod?.uppercased().hasSuffix("WEEKLY") == true
        }

        private enum CodingKeys: String, CodingKey {
            case planName
            case includedUsagePeriod
            case includedUsageResetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planName = try container.decodeIfPresent(String.self, forKey: .planName)
            includedUsagePeriod = try container.decodeIfPresent(String.self, forKey: .includedUsagePeriod)
            includedUsageResetsAt = try container
                .decodeIfPresent(CursorJSONEpoch.self, forKey: .includedUsageResetsAt)?
                .date
        }
    }
}

/// Epoch instant from a Connect JSON int64. Values above 1e12 are milliseconds.
/// Smaller finite values are seconds.
nonisolated struct CursorJSONEpoch: Decodable {
    let date: Date

    private static let millisecondThreshold: Double = 1_000_000_000_000

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try Self.rawValue(from: container)
        guard raw.isFinite, raw >= 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cursor epoch was not a finite instant"
            )
        }
        let seconds = raw > Self.millisecondThreshold ? raw / 1000 : raw
        date = Date(timeIntervalSince1970: seconds)
    }

    private static func rawValue(from container: SingleValueDecodingContainer) throws -> Double {
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Double(trimmed) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Cursor epoch string was not numeric"
                )
            }
            return parsed
        }
        if let int = try? container.decode(Int64.self) {
            return Double(int)
        }
        return try container.decode(Double.self)
    }
}
