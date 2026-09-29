import Foundation

/// The two hosts Z.ai's GLM Coding Plan monitor endpoints live on. The set is
/// closed on purpose: the user picks a region, never a URL, so a typo or a
/// pasted string can never send the key to an arbitrary host.
public enum ZaiCodingPlanRegion: String, Codable, CaseIterable, Sendable, Equatable {
    /// `api.z.ai` — the international platform.
    case international
    /// `open.bigmodel.cn` — the mainland China platform.
    case mainland

    public static let `default`: ZaiCodingPlanRegion = .international

    public var host: String {
        switch self {
        case .international: return "api.z.ai"
        case .mainland: return "open.bigmodel.cn"
        }
    }

    public var displayName: String {
        switch self {
        case .international: return "International (api.z.ai)"
        case .mainland: return "Mainland China (open.bigmodel.cn)"
        }
    }

    /// The single documented quota endpoint on this region's host.
    public var quotaLimitURL: URL? {
        URL(string: "https://\(host)/api/monitor/usage/quota/limit")
    }
}

/// Whether the GLM Coding Plan is currently charging its peak or off-peak
/// credit rate, from the schedule Z.ai publishes in its Coding Plan overview:
///
/// - Peak: Monday to Friday, 14:00–18:00 Singapore time (UTC+8, no DST).
///   Off-peak usage is charged at 50% of the standard credit rate.
/// - Promotion: 25 September to 7 October 2026, all-day usage is charged at the
///   off-peak rate.
///
/// Pure local-clock logic — no request is made. The schedule is data, not
/// behaviour: if Z.ai changes it, this table is what changes. It is stated
/// identically on the international and mainland docs.
public enum ZaiPeakSchedule {
    public struct Status: Equatable, Sendable {
        public let isPeak: Bool
        /// True when off-peak pricing applies only because of the published
        /// all-day promotion, so a "peak hours" label would be misleading.
        public let isPromotion: Bool
        /// The next moment the rate changes, or `nil` if none is found within
        /// the search horizon.
        public let nextChange: Date?

        public init(isPeak: Bool, isPromotion: Bool, nextChange: Date?) {
            self.isPeak = isPeak
            self.isPromotion = isPromotion
            self.nextChange = nextChange
        }
    }

    private static let offset = 8 * 3_600
    private static let peakStartHour = 14
    private static let peakEndHour = 18
    /// Search horizon for `nextChange`; a week always contains a boundary.
    private static let horizonDays = 14

    /// 2026-09-25 00:00 → 2026-10-08 00:00, UTC+8 (the docs' "September 25 to
    /// October 7", end date inclusive).
    private static let promotions: [(start: Date, end: Date)] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
        guard let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)),
              let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)) else {
            return []
        }
        return [(start, end)]
    }()

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
        return calendar
    }

    public static func status(at now: Date) -> Status {
        let current = rate(at: now)
        return Status(
            isPeak: current.isPeak,
            isPromotion: current.isPromotion,
            nextChange: nextChange(after: now, from: current.isPeak)
        )
    }

    private static func rate(at date: Date) -> (isPeak: Bool, isPromotion: Bool) {
        let scheduledPeak = isScheduledPeak(at: date)
        if scheduledPeak, promotions.contains(where: { date >= $0.start && date < $0.end }) {
            return (false, true)
        }
        return (scheduledPeak, false)
    }

    private static func isScheduledPeak(at date: Date) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return false }
        // Gregorian weekday: 1 = Sunday … 7 = Saturday.
        return (2...6).contains(weekday) && hour >= peakStartHour && hour < peakEndHour
    }

    /// Walks the candidate boundaries — each day's peak start and end, plus the
    /// promotion edges — and returns the first at which the effective rate flips.
    private static func nextChange(after now: Date, from isPeak: Bool) -> Date? {
        let calendar = calendar
        let startOfToday = calendar.startOfDay(for: now)
        var boundaries: [Date] = promotions.flatMap { [$0.start, $0.end] }
        for day in 0..<horizonDays {
            guard let date = calendar.date(byAdding: .day, value: day, to: startOfToday) else { continue }
            for hour in [peakStartHour, peakEndHour] {
                if let boundary = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) {
                    boundaries.append(boundary)
                }
            }
        }
        return boundaries
            .filter { $0 > now }
            .sorted()
            .first { rate(at: $0).isPeak != isPeak }
    }
}
