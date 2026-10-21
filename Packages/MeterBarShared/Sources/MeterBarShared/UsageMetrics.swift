import Foundation

/// Whether paid "extra usage" / overage credits are enabled for a service.
///
/// Claude Code and Grok ("extra usage") plus Codex ("credits") let an account spend
/// beyond its subscription quota once exhausted. Surfacing this lets users confirm
/// at a glance whether they can be billed for overage, or whether usage is hard-capped.
public struct ExtraUsageStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Extra paid usage / credits are enabled — overage spending is possible.
        case on
        /// Disabled — usage is capped at the subscription quota.
        case off
        /// Could not be determined (e.g. token unavailable or request failed).
        case unknown
    }

    public let state: State
    /// Short human-readable detail, e.g. "$0.00 used", "$5.00 in credits".
    public let detail: String?

    public init(state: State, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    public static let unknown = ExtraUsageStatus(state: .unknown, detail: nil)

    public var isOn: Bool { state == .on }

    /// Formats an amount as USD ("$5.00"); falls back to "<amount> <currency>" for others.
    public static func formatAmount(_ amount: Double, currency: String? = "USD") -> String {
        UsageAmountFormat.currency(amount, code: currency)
    }
}

public struct UsageMetrics: Codable, Identifiable, Sendable {
    public let id: UUID
    public let service: ServiceType
    public let sessionLimit: UsageLimit?
    public let weeklyLimit: UsageLimit?
    public let codeReviewLimit: UsageLimit?
    /// Provider-reported label for the model-scoped third quota window.
    ///
    /// Claude CLI has used both "Sonnet" and "Fable" for this window. Keeping
    /// the optional label alongside the existing limit preserves that identity
    /// without renaming the shared cache key or breaking older cached payloads.
    public let modelLimitLabel: String?
    public let extraUsage: ExtraUsageStatus?
    /// Number of banked rate-limit resets the account can trigger on demand.
    /// Codex (OpenAI reset credits) and Grok (usage-limit reset tokens). `nil`
    /// when the provider did not report the feature.
    public let resetCreditsAvailable: Int?
    /// Extra readable periods that did not fit the three legacy slots.
    ///
    /// A second weekly window, a daily allowance next to session/weekly, or a
    /// monthly period that arrived after `weeklyLimit` was already filled.
    /// Missing on older cached payloads; decodes as empty.
    public let additionalQuotaReadings: [QuotaReading]
    public var additionalLimits: [UsageLimit] { additionalQuotaReadings.compactMap { $0.window?.limit } }
    public let lastUpdated: Date
    private let invalidQuotaWindows: Set<QuotaWindowID>

    public var hasInvalidQuota: Bool {
        !invalidQuotaWindows.isEmpty || additionalQuotaReadings.contains(.unavailable(.parseDrift))
    }
    public var hasInvalidBlockingQuota: Bool {
        invalidQuotaWindows.contains(.session) || invalidQuotaWindows.contains(.weekly)
    }

    private static func invalidWindows(
        session: UsageLimit?, weekly: UsageLimit?, codeReview: UsageLimit?
    ) -> Set<QuotaWindowID> {
        var result: Set<QuotaWindowID> = []
        for (id, limit): (QuotaWindowID, UsageLimit?) in [
            (.session, session), (.weekly, weekly), (.codeReview, codeReview)
        ] {
            if let limit, !QuotaWindow.isValid(limit) { result.insert(id) }
        }
        return result
    }

    public init(
        service: ServiceType,
        sessionLimit: UsageLimit? = nil,
        weeklyLimit: UsageLimit? = nil,
        codeReviewLimit: UsageLimit? = nil,
        modelLimitLabel: String? = nil,
        extraUsage: ExtraUsageStatus? = nil,
        resetCreditsAvailable: Int? = nil,
        additionalLimits: [UsageLimit] = [],
        lastUpdated: Date = Date()
    ) {
        self.id = UUID()
        self.service = service
        self.invalidQuotaWindows = Self.invalidWindows(
            session: sessionLimit, weekly: weeklyLimit, codeReview: codeReviewLimit
        )
        self.sessionLimit = QuotaReading.validated(sessionLimit)
        self.weeklyLimit = QuotaReading.validated(weeklyLimit)
        self.codeReviewLimit = QuotaReading.validated(codeReviewLimit)
        self.modelLimitLabel = modelLimitLabel
        self.extraUsage = extraUsage
        self.resetCreditsAvailable = resetCreditsAvailable
        let account = ProviderAccount(service: service, scope: .providerWide)
        self.additionalQuotaReadings = additionalLimits.enumerated().map { index, limit in
            QuotaReading(limit: limit, account: account, id: .additional(UInt(index)))
        }
        self.lastUpdated = lastUpdated
    }

    private init(
        id: UUID,
        service: ServiceType,
        sessionLimit: UsageLimit?,
        weeklyLimit: UsageLimit?,
        codeReviewLimit: UsageLimit?,
        modelLimitLabel: String?,
        extraUsage: ExtraUsageStatus?,
        resetCreditsAvailable: Int?,
        additionalQuotaReadings: [QuotaReading],
        lastUpdated: Date,
        invalidQuotaWindows: Set<QuotaWindowID>
    ) {
        self.id = id
        self.service = service
        self.invalidQuotaWindows = invalidQuotaWindows
        self.sessionLimit = QuotaReading.validated(sessionLimit)
        self.weeklyLimit = QuotaReading.validated(weeklyLimit)
        self.codeReviewLimit = QuotaReading.validated(codeReviewLimit)
        self.modelLimitLabel = modelLimitLabel
        self.extraUsage = extraUsage
        self.resetCreditsAvailable = resetCreditsAvailable
        self.additionalQuotaReadings = additionalQuotaReadings
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case service
        case sessionLimit
        case weeklyLimit
        case codeReviewLimit
        case modelLimitLabel
        case extraUsage
        case resetCreditsAvailable
        case additionalLimits
        case lastUpdated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        service = try container.decode(ServiceType.self, forKey: .service)
        let rawSessionLimit = try container.decodeIfPresent(UsageLimit.self, forKey: .sessionLimit)
        sessionLimit = QuotaReading.validated(rawSessionLimit)
        let rawWeeklyLimit = try container.decodeIfPresent(UsageLimit.self, forKey: .weeklyLimit)
        weeklyLimit = QuotaReading.validated(rawWeeklyLimit)
        let rawCodeReviewLimit = try container.decodeIfPresent(UsageLimit.self, forKey: .codeReviewLimit)
        codeReviewLimit = QuotaReading.validated(rawCodeReviewLimit)
        modelLimitLabel = try container.decodeIfPresent(String.self, forKey: .modelLimitLabel)
        extraUsage = try container.decodeIfPresent(ExtraUsageStatus.self, forKey: .extraUsage)
        resetCreditsAvailable = try container.decodeIfPresent(Int.self, forKey: .resetCreditsAvailable)
        let rawAdditional = try container.decodeIfPresent([UsageLimit].self, forKey: .additionalLimits) ?? []
        let account = ProviderAccount(service: service, scope: .providerWide)
        additionalQuotaReadings = rawAdditional.enumerated().map { index, limit in
            QuotaReading(limit: limit, account: account, id: .additional(UInt(index)))
        }
        invalidQuotaWindows = Self.invalidWindows(
            session: rawSessionLimit, weekly: rawWeeklyLimit, codeReview: rawCodeReviewLimit
        )
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }

    public func encode(to encoder: Encoder) throws {
        // Older readers know only the optional limit fields. Omitting a bad
        // blocking window would let them route using only its healthy sibling.
        guard !hasInvalidBlockingQuota else {
            throw EncodingError.invalidValue(service.rawValue, .init(
                codingPath: encoder.codingPath, debugDescription: "Unavailable blocking quota cannot be cached"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(service, forKey: .service)
        try container.encodeIfPresent(sessionLimit, forKey: .sessionLimit)
        try container.encodeIfPresent(weeklyLimit, forKey: .weeklyLimit)
        try container.encodeIfPresent(codeReviewLimit, forKey: .codeReviewLimit)
        try container.encodeIfPresent(modelLimitLabel, forKey: .modelLimitLabel)
        try container.encodeIfPresent(extraUsage, forKey: .extraUsage)
        try container.encodeIfPresent(resetCreditsAvailable, forKey: .resetCreditsAvailable)
        if !additionalLimits.isEmpty {
            try container.encode(additionalLimits, forKey: .additionalLimits)
        }
        try container.encode(lastUpdated, forKey: .lastUpdated)
    }

    /// A caller must name the provider/account and window it intends to read.
    /// Provider-wide snapshots cannot silently satisfy a different service.
    public func quotaReading(for id: QuotaWindowID, account: ProviderAccount) -> QuotaReading {
        guard account.service == service else { return .unavailable(.parseDrift) }
        if invalidQuotaWindows.contains(id) { return .unavailable(.parseDrift) }
        let limit: UsageLimit?
        switch id {
        case .session: limit = sessionLimit
        case .weekly: limit = weeklyLimit
        case .codeReview: limit = codeReviewLimit
        case let .additional(index):
            guard index < UInt(additionalQuotaReadings.count) else { return .unavailable(.unsupported) }
            let reading = additionalQuotaReadings[Int(index)]
            guard let window = reading.window else { return reading }
            limit = window.limit
        }
        return QuotaReading(limit: limit, account: account, id: id)
    }

    /// Returns a copy with the given reset-credit count, preserving identity,
    /// limits, extra usage, and timestamp.
    public func withResetCreditsAvailable(_ count: Int?) -> UsageMetrics {
        UsageMetrics(
            id: id,
            service: service,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: codeReviewLimit,
            modelLimitLabel: modelLimitLabel,
            extraUsage: extraUsage,
            resetCreditsAvailable: count,
            additionalQuotaReadings: additionalQuotaReadings,
            lastUpdated: lastUpdated,
            invalidQuotaWindows: invalidQuotaWindows
        )
    }

    /// Returns a copy with the given extra-usage status, preserving identity, limits,
    /// reset credits, and timestamp.
    public func withExtraUsage(_ status: ExtraUsageStatus?) -> UsageMetrics {
        UsageMetrics(
            id: id,
            service: service,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: codeReviewLimit,
            modelLimitLabel: modelLimitLabel,
            extraUsage: status,
            resetCreditsAvailable: resetCreditsAvailable,
            additionalQuotaReadings: additionalQuotaReadings,
            lastUpdated: lastUpdated,
            invalidQuotaWindows: invalidQuotaWindows
        )
    }

    /// Provider-wide status derived from the windows that can block normal use.
    ///
    /// A model-scoped Sonnet/Fable or code-review limit can be exhausted while
    /// the rest of a provider remains available, so it stays visible on its row
    /// without turning the widget's provider status critical.
    public var overallStatus: UsageStatus {
        if let credit = additionalLimits.first(where: { $0.reading != .measured }) {
            switch credit.reading {
            case .remainder, .unlimited:
                return .good
            case .allowance:
                return credit.statusColor
            case .measured:
                break
            }
        }
        let limits = [sessionLimit, weeklyLimit].compactMap { $0 }
        guard !limits.isEmpty else { return .good }

        if limits.contains(where: { $0.statusColor == .critical }) {
            return .critical
        } else if limits.contains(where: { $0.statusColor == .warning }) {
            return .warning
        } else {
            return .good
        }
    }

    public var hasData: Bool {
        sessionLimit != nil
            || weeklyLimit != nil
            || codeReviewLimit != nil
            || !additionalLimits.isEmpty
    }
}
