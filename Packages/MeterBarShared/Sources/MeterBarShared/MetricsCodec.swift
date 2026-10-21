import Foundation

/// Single owner of the cached-usage ⇄ JSON wire formats — provider-keyed
/// `[ServiceType: UsageMetrics]` and the account-scoped `[AccountUsageSnapshot]` — shared
/// by the app's UserDefaults cache, the app-group file read by the widget and
/// CLI, and any future consumer. Previously this mapping was re-implemented in
/// four places (UsageDataManager, SharedDataStore, the widget, the CLI).
///
/// Decoding is tolerant per entry: an unknown `ServiceType` raw value or a
/// malformed entry drops only that entry instead of discarding the whole cache.
/// This matters across app updates — e.g. when a provider is removed, caches
/// written by older versions still decode for the providers that remain.
public enum MetricsCodec {
    public static func encode(_ metrics: [ServiceType: UsageMetrics]) -> Data? {
        let keyed = metrics.reduce(into: [String: UsageMetrics]()) { result, pair in
            guard !pair.value.hasInvalidBlockingQuota else { return }
            result[pair.key.rawValue] = pair.value
        }
        return try? JSONEncoder().encode(keyed)
    }

    public static func decode(_ data: Data) -> [ServiceType: UsageMetrics] {
        guard let keyed = try? JSONDecoder().decode([String: FailableBox<UsageMetrics>].self, from: data) else {
            return [:]
        }

        var decoded: [String: UsageMetrics] = [:]
        for (key, box) in keyed {
            guard ServiceType(rawValue: key) != nil,
                  let metrics = box.value, !metrics.hasInvalidBlockingQuota else { continue }
            decoded[key] = metrics
        }

        // Caches written before the xAI merge hold separate "Grok" and "Cursor"
        // entries that both resolve to `.xai`. Fold them into one card instead
        // of letting dictionary order pick a winner and drop the other source.
        var result: [ServiceType: UsageMetrics] = [:]
        for (key, metrics) in decoded where !ServiceType.legacyXAIRawValues.contains(key) {
            if let service = ServiceType(rawValue: key) {
                result[service] = metrics
            }
        }
        let xai = XAIUsageMerger.merge(
            grok: decoded[ServiceType.xai.rawValue] ?? decoded["Grok"],
            cursor: decoded["Cursor"]
        )
        if let xai {
            result[.xai] = xai
        }
        return result
    }

    public static func encodeAccounts(_ snapshots: [AccountUsageSnapshot]) -> Data? {
        try? JSONEncoder().encode(snapshots.filter { !$0.metrics.hasInvalidBlockingQuota })
    }

    /// Decodes the account-scoped cache with the same per-entry tolerance the
    /// provider-keyed cache has.
    ///
    /// One snapshot whose `service` raw value this build does not know — a cache
    /// written by a newer version, a provider since removed, a half-written
    /// array — drops alone. Failing the array here would blank the widget for
    /// every account, not just the unreadable one.
    public static func decodeAccounts(_ data: Data) -> [AccountUsageSnapshot] {
        guard let boxed = try? JSONDecoder().decode([FailableBox<AccountUsageSnapshot>].self, from: data) else {
            return []
        }
        return boxed.compactMap(\.value).filter { !$0.metrics.hasInvalidBlockingQuota }
    }
}
