import Foundation

/// Whether paid "extra usage" / overage credits are enabled for a service.
///
/// Both Claude Code ("extra usage") and Codex ("credits") let an account spend
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
        let normalized = (currency ?? "USD").uppercased()
        if normalized == "USD" {
            return String(format: "$%.2f", amount)
        }
        return String(format: "%.2f %@", amount, normalized)
    }
}

public struct UsageMetrics: Codable, Identifiable, Sendable {
    public let id: UUID
    public let service: ServiceType
    public let sessionLimit: UsageLimit?
    public let weeklyLimit: UsageLimit?
    public let codeReviewLimit: UsageLimit?
    public let extraUsage: ExtraUsageStatus?
    /// Number of banked rate-limit resets the account can trigger on demand.
    /// Codex-only (OpenAI "reset credits"); `nil` for providers/accounts without the feature.
    public let resetCreditsAvailable: Int?
    public let lastUpdated: Date

    public init(
        service: ServiceType,
        sessionLimit: UsageLimit? = nil,
        weeklyLimit: UsageLimit? = nil,
        codeReviewLimit: UsageLimit? = nil,
        extraUsage: ExtraUsageStatus? = nil,
        resetCreditsAvailable: Int? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = UUID()
        self.service = service
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.codeReviewLimit = codeReviewLimit
        self.extraUsage = extraUsage
        self.resetCreditsAvailable = resetCreditsAvailable
        self.lastUpdated = lastUpdated
    }

    private init(
        id: UUID,
        service: ServiceType,
        sessionLimit: UsageLimit?,
        weeklyLimit: UsageLimit?,
        codeReviewLimit: UsageLimit?,
        extraUsage: ExtraUsageStatus?,
        resetCreditsAvailable: Int?,
        lastUpdated: Date
    ) {
        self.id = id
        self.service = service
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.codeReviewLimit = codeReviewLimit
        self.extraUsage = extraUsage
        self.resetCreditsAvailable = resetCreditsAvailable
        self.lastUpdated = lastUpdated
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
            extraUsage: status,
            resetCreditsAvailable: resetCreditsAvailable,
            lastUpdated: lastUpdated
        )
    }

    public var overallStatus: UsageStatus {
        let limits = [sessionLimit, weeklyLimit, codeReviewLimit].compactMap { $0 }
        guard !limits.isEmpty else { return .good }

        if limits.contains(where: { $0.isAtLimit }) {
            return .critical
        } else if limits.contains(where: { $0.isNearLimit }) {
            return .warning
        } else {
            return .good
        }
    }

    public var hasData: Bool {
        return sessionLimit != nil || weeklyLimit != nil || codeReviewLimit != nil
    }
}
