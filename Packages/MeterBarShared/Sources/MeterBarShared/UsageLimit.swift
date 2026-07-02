import Foundation

public struct UsageLimit: Codable, Equatable, Sendable {
    public let used: Double
    public let total: Double
    public let resetTime: Date?
    public let windowSeconds: TimeInterval?

    public init(used: Double, total: Double, resetTime: Date?, windowSeconds: TimeInterval? = nil) {
        self.used = used
        self.total = total
        self.resetTime = resetTime
        self.windowSeconds = windowSeconds
    }

    public var rawPercentage: Double {
        guard total > 0 else { return 0 }
        return max(0, (used / total) * 100)
    }

    public var percentage: Double {
        return min(100, rawPercentage)
    }

    /// `used` clamped into `0...total`, for progress bars that reject
    /// out-of-range values (e.g. `ProgressView`).
    public var clampedUsed: Double {
        return max(0, min(used, total))
    }

    /// `total` clamped away from zero so progress-bar math never divides by 0.
    public var clampedTotal: Double {
        return max(0.001, total)
    }

    // Severity thresholds and "% left" live in `QuotaBands` — the single
    // source of truth for every surface. Only the hard at-limit check stays.
    public var isAtLimit: Bool {
        return percentage >= 100
    }

    /// Three-level status derived from the shared `QuotaBand` thresholds, for
    /// surfaces (widget) that render good/warning/critical directly.
    public var statusColor: UsageStatus {
        QuotaBand.forLimit(self).status
    }

    public func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let resetTime else { return nil }
        return resetTime.timeIntervalSince(now)
    }

    public func resetCountdownText(now: Date = Date()) -> String? {
        guard let secondsUntilReset = secondsUntilReset(now: now) else { return nil }
        guard secondsUntilReset > 0 else { return "now" }
        return UsageDurationText.short(seconds: secondsUntilReset)
    }

    public func pace(now: Date = Date()) -> UsagePace? {
        guard let resetTime,
              let windowSeconds,
              windowSeconds > 0 else {
            return nil
        }

        let remainingSeconds = resetTime.timeIntervalSince(now)
        guard remainingSeconds > 0, remainingSeconds <= windowSeconds else {
            return nil
        }

        let elapsedSeconds = min(windowSeconds, max(0, windowSeconds - remainingSeconds))
        let expectedUsedPercent = min(100, max(0, elapsedSeconds / windowSeconds * 100))
        let deltaPercent = rawPercentage - expectedUsedPercent

        if elapsedSeconds == 0, rawPercentage > 0 {
            return nil
        }

        let etaSeconds: TimeInterval?
        let willLastToReset: Bool
        if rawPercentage >= 100 {
            etaSeconds = 0
            willLastToReset = false
        } else if elapsedSeconds <= 0 || rawPercentage <= 0 {
            etaSeconds = nil
            willLastToReset = true
        } else {
            let burnRatePercentPerSecond = rawPercentage / elapsedSeconds
            let secondsUntilEmpty = (100 - rawPercentage) / burnRatePercentPerSecond
            etaSeconds = secondsUntilEmpty
            willLastToReset = secondsUntilEmpty >= remainingSeconds
        }

        return UsagePace(
            expectedUsedPercent: expectedUsedPercent,
            deltaPercent: deltaPercent,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset
        )
    }
}

public struct UsagePace: Equatable, Sendable {
    public enum Stage: Sendable {
        case onPace
        case reserve
        case deficit
    }

    public let expectedUsedPercent: Double
    public let deltaPercent: Double
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool

    public init(
        expectedUsedPercent: Double,
        deltaPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool
    ) {
        self.expectedUsedPercent = expectedUsedPercent
        self.deltaPercent = deltaPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
    }

    public var stage: Stage {
        if abs(deltaPercent) <= 2 {
            return .onPace
        }
        return deltaPercent > 0 ? .deficit : .reserve
    }

    public var isExhausted: Bool {
        etaSeconds == 0 && !willLastToReset
    }

    public var leftLabel: String {
        if isExhausted {
            return "Out of quota"
        }

        let roundedDelta = Int(abs(deltaPercent).rounded())
        switch stage {
        case .onPace:
            return "On pace"
        case .reserve:
            return "\(roundedDelta)% in reserve"
        case .deficit:
            return "\(roundedDelta)% in deficit"
        }
    }

    public func rightLabel(context: PaceLabelContext = .session) -> String? {
        if isExhausted {
            return "Out until reset"
        }

        if willLastToReset {
            return "Lasts until reset"
        }

        guard let etaSeconds else {
            return nil
        }

        if etaSeconds <= 30 {
            return context.emptyNowLabel
        }

        return "\(context.emptyPrefix) \(UsageDurationText.short(seconds: etaSeconds))"
    }
}

public enum UsageDurationText {
    public static func short(seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        let days = wholeSeconds / 86_400
        let hours = (wholeSeconds % 86_400) / 3_600
        let minutes = (wholeSeconds % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if wholeSeconds < 60 {
            return "<1m"
        }
        return "\(minutes)m"
    }
}

public enum PaceLabelContext: Sendable {
    case session
    case weekly

    public var emptyNowLabel: String {
        switch self {
        case .session:
            return "Projected empty now"
        case .weekly:
            return "Runs out now"
        }
    }

    public var emptyPrefix: String {
        switch self {
        case .session:
            return "Projected empty in"
        case .weekly:
            return "Runs out in"
        }
    }
}
