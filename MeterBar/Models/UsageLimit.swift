import Foundation
import SwiftUI

struct UsageLimit: Codable, Equatable {
    let used: Double
    let total: Double
    let resetTime: Date?
    let windowSeconds: TimeInterval?

    init(used: Double, total: Double, resetTime: Date?, windowSeconds: TimeInterval? = nil) {
        self.used = used
        self.total = total
        self.resetTime = resetTime
        self.windowSeconds = windowSeconds
    }

    var rawPercentage: Double {
        guard total > 0 else { return 0 }
        return max(0, (used / total) * 100)
    }
    
    var percentage: Double {
        return min(100, rawPercentage)
    }
    
    var remaining: Double {
        return max(0, total - used)
    }
    
    var isNearLimit: Bool {
        return percentage >= 80
    }
    
    var isAtLimit: Bool {
        return percentage >= 100
    }
    
    var statusColor: UsageStatus {
        if isAtLimit {
            return .critical
        } else if isNearLimit {
            return .warning
        } else {
            return .good
        }
    }

    func secondsUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let resetTime else { return nil }
        return resetTime.timeIntervalSince(now)
    }

    func resetCountdownText(now: Date = Date()) -> String? {
        guard let secondsUntilReset = secondsUntilReset(now: now) else { return nil }
        guard secondsUntilReset > 0 else { return "now" }
        return UsageDurationText.short(seconds: secondsUntilReset)
    }

    func pace(now: Date = Date()) -> UsagePace? {
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

struct UsagePace: Equatable {
    enum Stage {
        case onPace
        case reserve
        case deficit
    }

    let expectedUsedPercent: Double
    let deltaPercent: Double
    let etaSeconds: TimeInterval?
    let willLastToReset: Bool

    var stage: Stage {
        if abs(deltaPercent) <= 2 {
            return .onPace
        }
        return deltaPercent > 0 ? .deficit : .reserve
    }

    var isExhausted: Bool {
        etaSeconds == 0 && !willLastToReset
    }

    var leftLabel: String {
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

    func rightLabel(context: PaceLabelContext = .session) -> String? {
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

enum UsageDurationText {
    static func short(seconds: TimeInterval) -> String {
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

enum PaceLabelContext {
    case session
    case weekly

    var emptyNowLabel: String {
        switch self {
        case .session:
            return "Projected empty now"
        case .weekly:
            return "Runs out now"
        }
    }

    var emptyPrefix: String {
        switch self {
        case .session:
            return "Projected empty in"
        case .weekly:
            return "Runs out in"
        }
    }
}

enum UsageStatus {
    case good
    case warning
    case critical

    var color: Color {
        switch self {
        case .good: return MeterBarTheme.success
        case .warning: return MeterBarTheme.warning
        case .critical: return MeterBarTheme.danger
        }
    }
}
