import Foundation
import MeterBarShared

/// Keeps a previous Muse window only while its reset is still in the future.
///
/// An idle response omits `subs_usage` entirely. That must not become 0%, and
/// a window with no reset — or a reset that has already passed — is not
/// evidence the old percentage still applies.
nonisolated enum MuseCodeIdleRetention {
    static func retained(from previous: UsageMetrics?, now: Date) -> UsageMetrics? {
        guard let previous else { return nil }
        let session = keep(previous.sessionLimit, now: now)
        let weekly = keep(previous.weeklyLimit, now: now)
        guard session != nil || weekly != nil else { return nil }
        return UsageMetrics(
            service: .museCode,
            sessionLimit: session,
            weeklyLimit: weekly,
            lastUpdated: previous.lastUpdated
        )
    }

    private static func keep(_ limit: UsageLimit?, now: Date) -> UsageLimit? {
        guard let limit, let resetTime = limit.resetTime, resetTime > now else { return nil }
        return limit
    }
}
