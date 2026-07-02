import Foundation

/// Single owner of the `[ServiceType: UsageMetrics]` ⇄ JSON wire format shared
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
            result[pair.key.rawValue] = pair.value
        }
        return try? JSONEncoder().encode(keyed)
    }

    public static func decode(_ data: Data) -> [ServiceType: UsageMetrics] {
        guard let keyed = try? JSONDecoder().decode([String: FailableBox<UsageMetrics>].self, from: data) else {
            return [:]
        }

        return keyed.reduce(into: [ServiceType: UsageMetrics]()) { result, pair in
            guard let service = ServiceType(rawValue: pair.key),
                  let metrics = pair.value.value else {
                return
            }
            result[service] = metrics
        }
    }
}

/// Wraps a decodable value so one bad element degrades to `nil` instead of
/// failing the containing collection's decode.
private struct FailableBox<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
