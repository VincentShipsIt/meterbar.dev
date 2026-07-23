import Foundation
import MeterBarShared

/// What happened to one provider during a `UsageDataManager` refresh pass.
nonisolated public enum ProviderRefreshState: String, Codable, Equatable, Sendable {
    case refreshed
    case failed
    case skipped
}

/// One provider's outcome, including whether graceful degradation retained a
/// last-known-good value.
nonisolated public struct ProviderRefreshOutcome: Codable, Equatable, Sendable {
    public let provider: ServiceType
    public let state: ProviderRefreshState
    public let reason: String?
    public let servedFromCache: Bool
    public let lastUpdated: Date?

    public init(
        provider: ServiceType,
        state: ProviderRefreshState,
        reason: String? = nil,
        servedFromCache: Bool = false,
        lastUpdated: Date? = nil
    ) {
        self.provider = provider
        self.state = state
        self.reason = reason
        self.servedFromCache = servedFromCache
        self.lastUpdated = lastUpdated
    }
}

/// The structured result of one `UsageDataManager.refreshAll()` pass.
nonisolated public struct UsageRefreshReport: Equatable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let outcomes: [ProviderRefreshOutcome]

    public init(startedAt: Date, finishedAt: Date, outcomes: [ProviderRefreshOutcome]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes.sorted { $0.provider.sortOrder < $1.provider.sortOrder }
    }

    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    public func outcome(for provider: ServiceType) -> ProviderRefreshOutcome? {
        outcomes.first { $0.provider == provider }
    }

    public func count(of state: ProviderRefreshState) -> Int {
        outcomes.filter { $0.state == state }.count
    }
}
