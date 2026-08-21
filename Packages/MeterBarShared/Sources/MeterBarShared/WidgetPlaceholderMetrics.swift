import Foundation

/// Synthetic metrics the widget extension shows before a timeline loads.
///
/// Built from an exhaustive `ServiceType` switch so a new provider is a
/// compile error here and a test failure in `WidgetBurnDownTests` until the
/// placeholder is updated.
public enum WidgetPlaceholderMetrics {
    public static func burnDown(now: Date = Date()) -> [ServiceType: UsageMetrics] {
        Dictionary(uniqueKeysWithValues: ServiceType.allCases.map { service in
            (service, metrics(for: service, now: now))
        })
    }

    private static func metrics(for service: ServiceType, now: Date) -> UsageMetrics {
        let used: Double
        let resetDelay: TimeInterval
        switch service {
        case .claudeCode:
            used = 72
            resetDelay = 2.5 * 24 * 60 * 60
        case .codexCli:
            used = 38
            resetDelay = 4 * 24 * 60 * 60
        case .cursor:
            used = 55
            resetDelay = 5 * 24 * 60 * 60
        case .grok:
            used = 47
            resetDelay = 3 * 24 * 60 * 60
        case .openRouter:
            used = 32
            resetDelay = 18 * 24 * 60 * 60
        }
        return UsageMetrics(
            service: service,
            weeklyLimit: UsageLimit(
                used: used,
                total: 100,
                resetTime: now.addingTimeInterval(resetDelay),
                windowSeconds: 7 * 24 * 60 * 60
            ),
            lastUpdated: now
        )
    }
}
