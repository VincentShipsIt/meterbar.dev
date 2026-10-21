import Foundation

extension MetricsCodec {
    /// Retains the shipped UUID-dictionary wire format, but one unreadable
    /// account no longer discards every healthy account in the same blob.
    public static func decodeAccountMap(_ data: Data, service: ServiceType) -> [UUID: UsageMetrics]? {
        guard let decoded = try? JSONDecoder().decode(AccountMetricEntries.self, from: data) else { return nil }
        var result: [UUID: UsageMetrics] = [:]
        for (id, metrics) in decoded.entries {
            guard metrics.service == service, !metrics.hasInvalidBlockingQuota else { continue }
            if let previous = result[id], previous.lastUpdated >= metrics.lastUpdated { continue }
            result[id] = metrics
        }
        return result
    }

    public static func encodeAccountMap(_ metrics: [UUID: UsageMetrics], service: ServiceType) -> Data? {
        let scoped = metrics.filter { $0.value.service == service && !$0.value.hasInvalidBlockingQuota }
        return try? JSONEncoder().encode(scoped)
    }
}

private struct AccountMetricEntries: Decodable {
    let entries: [(UUID, UsageMetrics)]

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var entries: [(UUID, UsageMetrics)] = []
            while !container.isAtEnd {
                let id = try container.decode(FailableBox<UUID>.self).value
                guard !container.isAtEnd else { break }
                let metrics = try container.decode(FailableBox<UsageMetrics>.self).value
                if let id, let metrics { entries.append((id, metrics)) }
            }
            self.entries = entries
        } else {
            // Accept readable object-keyed caches too; encoding remains the
            // original alternating UUID/value array produced by JSONEncoder.
            let keyed = try [String: FailableBox<UsageMetrics>](from: decoder)
            entries = keyed.compactMap { key, box in
                guard let id = UUID(uuidString: key), let metrics = box.value else { return nil }
                return (id, metrics)
            }
        }
    }
}
