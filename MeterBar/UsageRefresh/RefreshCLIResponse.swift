import Foundation
import MeterBarShared

/// Version 1 contract for `meterbar refresh --json`.
nonisolated public struct RefreshCLIResponse: CLIJSONDocument {
    public static let currentSchemaVersion = 1

    private let schemaVersion = currentSchemaVersion
    let outcome: RefreshCLIOutcome
    private let collectedAt: Date
    private let durationSeconds: Double
    private let providers: [Provider]
    private let cache: Cache
    let message: String?

    var summaryLine: String {
        let counts = [ProviderRefreshState.refreshed, .failed, .skipped]
            .map { state in "\(state.rawValue) \(providers.filter { $0.state == state }.count)" }
            .joined(separator: " · ")
        return "Refresh: \(outcome.rawValue) · \(counts) · cache \(cache.freshnessDescription)"
    }

    init(
        outcome: RefreshCLIOutcome,
        collectedAt: Date,
        durationSeconds: Double,
        outcomes: [ProviderRefreshOutcome],
        cachedMetrics: [ServiceType: UsageMetrics],
        message: String? = nil
    ) {
        self.outcome = outcome
        self.collectedAt = collectedAt
        self.durationSeconds = max(0, durationSeconds)
        providers = outcomes
            .sorted { $0.provider.sortOrder < $1.provider.sortOrder }
            .map(Provider.init(outcome:))
        cache = Cache(metrics: cachedMetrics, now: collectedAt)
        self.message = message
    }

    private struct Provider: Encodable {
        let provider: String
        let displayName: String
        let state: ProviderRefreshState
        let reason: String?
        let servedFromCache: Bool
        let lastUpdated: Date?

        init(outcome: ProviderRefreshOutcome) {
            provider = outcome.provider.cliIdentifier
            displayName = outcome.provider.displayName
            state = outcome.state
            reason = outcome.reason
            servedFromCache = outcome.servedFromCache
            lastUpdated = outcome.lastUpdated
        }
    }

    private struct Cache: Encodable {
        let providerCount: Int
        let lastUpdated: Date?
        let ageSeconds: Double?
        let isStale: Bool

        init(metrics: [ServiceType: UsageMetrics], now: Date) {
            providerCount = metrics.count
            let newest = metrics.values.map(\.lastUpdated).max()
            lastUpdated = newest
            guard let newest else {
                ageSeconds = nil
                isStale = true
                return
            }
            let age = max(0, now.timeIntervalSince(newest))
            ageSeconds = age
            isStale = age > ProviderParseHealthRecord.staleAfter
        }

        var freshnessDescription: String {
            guard let lastUpdated else { return "empty" }
            return UsageFormat.relative(lastUpdated) + (isStale ? " (stale)" : "")
        }
    }
}
