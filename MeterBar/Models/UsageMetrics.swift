import Foundation

/// Whether paid "extra usage" / overage credits are enabled for a service.
///
/// Both Claude Code ("extra usage") and Codex ("credits") let an account spend
/// beyond its subscription quota once exhausted. Surfacing this lets users confirm
/// at a glance whether they can be billed for overage, or whether usage is hard-capped.
struct ExtraUsageStatus: Codable, Equatable {
    enum State: String, Codable {
        /// Extra paid usage / credits are enabled — overage spending is possible.
        case on
        /// Disabled — usage is capped at the subscription quota.
        case off
        /// Could not be determined (e.g. token unavailable or request failed).
        case unknown
    }

    let state: State
    /// Short human-readable detail, e.g. "$0.00 used", "$5.00 in credits".
    let detail: String?

    init(state: State, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    static let unknown = ExtraUsageStatus(state: .unknown, detail: nil)

    var isOn: Bool { state == .on }

    /// Formats an amount as USD ("$5.00"); falls back to "<amount> <currency>" for others.
    static func formatAmount(_ amount: Double, currency: String? = "USD") -> String {
        let normalized = (currency ?? "USD").uppercased()
        if normalized == "USD" {
            return String(format: "$%.2f", amount)
        }
        return String(format: "%.2f %@", amount, normalized)
    }
}

struct UsageMetrics: Codable, Identifiable {
    let id: UUID
    let service: ServiceType
    let sessionLimit: UsageLimit?
    let weeklyLimit: UsageLimit?
    let codeReviewLimit: UsageLimit?
    let extraUsage: ExtraUsageStatus?
    let lastUpdated: Date

    init(
        service: ServiceType,
        sessionLimit: UsageLimit? = nil,
        weeklyLimit: UsageLimit? = nil,
        codeReviewLimit: UsageLimit? = nil,
        extraUsage: ExtraUsageStatus? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = UUID()
        self.service = service
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.codeReviewLimit = codeReviewLimit
        self.extraUsage = extraUsage
        self.lastUpdated = lastUpdated
    }

    private init(
        id: UUID,
        service: ServiceType,
        sessionLimit: UsageLimit?,
        weeklyLimit: UsageLimit?,
        codeReviewLimit: UsageLimit?,
        extraUsage: ExtraUsageStatus?,
        lastUpdated: Date
    ) {
        self.id = id
        self.service = service
        self.sessionLimit = sessionLimit
        self.weeklyLimit = weeklyLimit
        self.codeReviewLimit = codeReviewLimit
        self.extraUsage = extraUsage
        self.lastUpdated = lastUpdated
    }

    /// Returns a copy with the given extra-usage status, preserving identity, limits, and timestamp.
    func withExtraUsage(_ status: ExtraUsageStatus?) -> UsageMetrics {
        UsageMetrics(
            id: id,
            service: service,
            sessionLimit: sessionLimit,
            weeklyLimit: weeklyLimit,
            codeReviewLimit: codeReviewLimit,
            extraUsage: status,
            lastUpdated: lastUpdated
        )
    }
    
    var overallStatus: UsageStatus {
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
    
    var hasData: Bool {
        return sessionLimit != nil || weeklyLimit != nil || codeReviewLimit != nil
    }
}

