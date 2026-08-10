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
    /// Present only when a caller-supplied input was rejected. Same shape as
    /// the guard error object so one consumer can read both commands.
    private let error: ErrorDetail?

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
        message: String? = nil,
        failure: RefreshCLIFailure? = nil
    ) {
        self.outcome = outcome
        self.collectedAt = collectedAt
        self.durationSeconds = max(0, durationSeconds)
        providers = outcomes
            .sorted { $0.provider.sortOrder < $1.provider.sortOrder }
            .map(Provider.init(outcome:))
        cache = Cache(metrics: cachedMetrics, now: collectedAt)
        self.message = message
        error = failure.map(ErrorDetail.init(failure:))
    }

    /// A rejected `--timeout`: no provider was contacted, so the document
    /// carries the failure rather than an empty provider list that would read
    /// like a refresh that found nothing to do.
    init(
        failure: RefreshCLIFailure,
        collectedAt: Date,
        cachedMetrics: [ServiceType: UsageMetrics]
    ) {
        self.init(
            outcome: .refreshFailed,
            collectedAt: collectedAt,
            durationSeconds: 0,
            outcomes: [],
            cachedMetrics: cachedMetrics,
            message: failure.message,
            failure: failure
        )
    }

    private struct ErrorDetail: Encodable {
        let code: String
        let message: String
        let flag: String?
        let value: String?

        init(failure: RefreshCLIFailure) {
            code = failure.code
            message = failure.message
            flag = failure.flag
            value = failure.value
        }
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
