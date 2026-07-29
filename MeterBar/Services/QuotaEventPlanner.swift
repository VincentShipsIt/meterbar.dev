import Foundation
import MeterBarShared

/// Public quota transition names used by local hooks and webhook payloads.
nonisolated enum QuotaEventKind: String, Codable, CaseIterable, Sendable {
    case warning
    case critical
    case exhausted
    case recovered

    var displayName: String {
        switch self {
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .exhausted: return "Exhausted"
        case .recovered: return "Recovered"
        }
    }
}

/// Stable window names in the versioned webhook contract.
nonisolated enum QuotaEventWindow: String, Codable, CaseIterable, Sendable {
    case session
    case weekly
    case codeReview = "code_review"

    var displayName: String {
        switch self {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .codeReview: return "Model / code review"
        }
    }
}

/// Stable quota-band names in the versioned webhook contract.
nonisolated enum QuotaEventBand: String, Codable, Sendable {
    case healthy
    case tight
    case critical
    case exhausted

    init(_ band: QuotaBand) {
        switch band {
        case .healthy: self = .healthy
        case .tight: self = .tight
        case .critical: self = .critical
        case .exhausted: self = .exhausted
        }
    }

    var quotaBand: QuotaBand {
        switch self {
        case .healthy: return .healthy
        case .tight: return .tight
        case .critical: return .critical
        case .exhausted: return .exhausted
        }
    }
}

/// Minimal account identity safe to pass to an explicitly configured outbound
/// integration. It intentionally has no config directory or credential fields.
nonisolated struct QuotaEventAccount: Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

/// One provider/account metric snapshot evaluated by `QuotaEventPlanner`.
nonisolated struct QuotaEventSnapshot: Sendable {
    let provider: ServiceType
    let account: QuotaEventAccount
    let metrics: UsageMetrics
}

/// Version 1 public webhook body. Keep this minimal and additive: downstream
/// consumers may persist or route these fields independently of MeterBar.
nonisolated struct QuotaEventPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let provider: ServiceType
    let account: QuotaEventAccount
    let event: QuotaEventKind
    let window: QuotaEventWindow
    let percentage: Double
    let band: QuotaEventBand
    let timestamp: Date

    init(
        provider: ServiceType,
        account: QuotaEventAccount,
        event: QuotaEventKind,
        window: QuotaEventWindow,
        percentage: Double,
        band: QuotaEventBand,
        timestamp: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.account = account
        self.event = event
        self.window = window
        self.percentage = percentage
        self.band = band
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provider
        case account
        case event
        case window
        case percentage
        case band
        case timestamp
    }
}

/// Pure transition detector for every provider/account/window namespace.
///
/// The first observation primes state, so launching from a high cached value
/// never masquerades as a fresh crossing. Repeated states dedupe naturally.
/// A drop updates the namespace immediately (re-arming it), while the
/// per-event debounce timestamp suppresses rapid threshold flapping.
nonisolated struct QuotaEventPlanner: Sendable {
    private struct Namespace: Hashable, Sendable {
        let provider: ServiceType
        let accountID: String
        let window: QuotaEventWindow
    }

    private struct DeliveryKey: Hashable, Sendable {
        let namespace: Namespace
        let event: QuotaEventKind
    }

    private let debounceInterval: TimeInterval
    private var bands: [Namespace: QuotaEventBand] = [:]
    private var lastDeliveryDates: [DeliveryKey: Date] = [:]

    init(debounceInterval: TimeInterval = 60) {
        self.debounceInterval = max(0, debounceInterval)
    }

    mutating func evaluate(
        snapshots: [QuotaEventSnapshot],
        now: Date = Date()
    ) -> [QuotaEventPayload] {
        var payloads: [QuotaEventPayload] = []
        var activeNamespaces = Set<Namespace>()

        for snapshot in snapshots {
            let limits: [(QuotaEventWindow, UsageLimit?)] = [
                (.session, snapshot.metrics.sessionLimit),
                (.weekly, snapshot.metrics.weeklyLimit),
                (.codeReview, snapshot.metrics.codeReviewLimit),
            ]

            for (window, limit) in limits {
                let namespace = Namespace(
                    provider: snapshot.provider,
                    accountID: snapshot.account.id,
                    window: window
                )
                guard let limit, !limit.isEstimated else {
                    bands.removeValue(forKey: namespace)
                    continue
                }
                activeNamespaces.insert(namespace)

                let band = QuotaEventBand(QuotaBand.forLimit(limit))
                guard let previousBand = bands.updateValue(band, forKey: namespace) else {
                    continue
                }
                guard let event = transition(from: previousBand, to: band) else {
                    continue
                }

                let deliveryKey = DeliveryKey(namespace: namespace, event: event)
                if let lastDelivery = lastDeliveryDates[deliveryKey],
                   now.timeIntervalSince(lastDelivery) < debounceInterval {
                    continue
                }
                lastDeliveryDates[deliveryKey] = now

                payloads.append(QuotaEventPayload(
                    provider: snapshot.provider,
                    account: snapshot.account,
                    event: event,
                    window: window,
                    percentage: limit.percentage,
                    band: band,
                    timestamp: now
                ))
            }
        }

        let removedNamespaces = Set(bands.keys).subtracting(activeNamespaces)
        for namespace in removedNamespaces {
            bands.removeValue(forKey: namespace)
            lastDeliveryDates = lastDeliveryDates.filter { $0.key.namespace != namespace }
        }

        return payloads
    }

    private func transition(
        from previous: QuotaEventBand,
        to current: QuotaEventBand
    ) -> QuotaEventKind? {
        guard previous != current else { return nil }

        if current == .healthy, previous != .healthy {
            return .recovered
        }
        guard current.quotaBand.severityRank > previous.quotaBand.severityRank else { return nil }
        switch current {
        case .healthy: return nil
        case .tight: return .warning
        case .critical: return .critical
        case .exhausted: return .exhausted
        }
    }
}
