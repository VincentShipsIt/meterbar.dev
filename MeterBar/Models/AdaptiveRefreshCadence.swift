import Foundation
import IOKit.ps

/// Hard limits for Adaptive refresh. Production stays within the existing
/// fixed-choice range: never faster than one minute or slower than 30 minutes.
nonisolated struct AdaptiveRefreshBounds: Equatable, Sendable {
    static let standard = AdaptiveRefreshBounds(fastest: 60, slowest: 30 * 60)

    let fastest: TimeInterval
    let slowest: TimeInterval

    init(fastest: TimeInterval, slowest: TimeInterval) {
        let normalizedFastest = max(1, min(fastest, slowest))
        self.fastest = normalizedFastest
        self.slowest = max(normalizedFastest, slowest)
    }

    func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(slowest, max(fastest, interval))
    }
}

nonisolated enum AdaptiveRefreshThermalState: Int, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }
}

nonisolated struct AdaptiveRefreshPowerState: Equatable, Sendable {
    static let unconstrained = AdaptiveRefreshPowerState(
        isOnBattery: false,
        isLowPowerModeEnabled: false,
        thermalState: .nominal
    )

    let isOnBattery: Bool
    let isLowPowerModeEnabled: Bool
    let thermalState: AdaptiveRefreshThermalState

    static var current: AdaptiveRefreshPowerState {
        let processInfo = ProcessInfo.processInfo
        return AdaptiveRefreshPowerState(
            isOnBattery: SystemPowerSource.isOnBattery,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: AdaptiveRefreshThermalState(processInfo.thermalState)
        )
    }
}

/// The only ephemeral behavior inputs Adaptive refresh accepts. None of these
/// values are encoded, persisted, logged, or sent to a provider.
nonisolated struct AdaptiveRefreshSignals: Equatable, Sendable {
    let lastInteractionAt: Date?
    let lastQuotaMovementAt: Date?
    let power: AdaptiveRefreshPowerState
}

nonisolated enum AdaptiveRefreshTrigger: Equatable, Sendable {
    case scheduled
    case popoverOpened
    case manualRefresh
}

nonisolated enum AdaptiveRefreshReason: Equatable, Sendable {
    case recentQuotaMovement
    case recentInteraction
    case idle
    case batteryPower
    case lowPowerMode
    case thermalPressure
    case popoverOpened
    case manualRefresh

    var displayText: String {
        switch self {
        case .recentQuotaMovement:
            return "Recent quota movement."
        case .recentInteraction:
            return "Recent MeterBar interaction."
        case .idle:
            return "No recent MeterBar interaction or quota movement."
        case .batteryPower:
            return "Mac is running on battery power."
        case .lowPowerMode:
            return "Low Power Mode is enabled."
        case .thermalPressure:
            return "Thermal pressure is elevated."
        case .popoverOpened:
            return "Popover opened; refresh runs immediately."
        case .manualRefresh:
            return "Manual refresh requested; refresh runs immediately."
        }
    }
}

nonisolated struct AdaptiveRefreshDecision: Equatable, Sendable {
    let interval: TimeInterval
    let reason: AdaptiveRefreshReason
}

/// Pure cadence policy with an injected clock. It reads no global state and
/// mutates nothing; callers supply every activity and power signal explicitly.
nonisolated struct AdaptiveRefreshCadenceEngine: Sendable {
    typealias Clock = @Sendable () -> Date

    static let activityWindow: TimeInterval = 10 * 60

    private let bounds: AdaptiveRefreshBounds
    private let now: Clock

    init(
        bounds: AdaptiveRefreshBounds = .standard,
        now: @escaping Clock = { Date() }
    ) {
        self.bounds = bounds
        self.now = now
    }

    func decision(
        signals: AdaptiveRefreshSignals,
        trigger: AdaptiveRefreshTrigger = .scheduled
    ) -> AdaptiveRefreshDecision {
        switch trigger {
        case .popoverOpened:
            return AdaptiveRefreshDecision(interval: 0, reason: .popoverOpened)
        case .manualRefresh:
            return AdaptiveRefreshDecision(interval: 0, reason: .manualRefresh)
        case .scheduled:
            break
        }

        let currentDate = now()
        let hasRecentMovement = isRecent(signals.lastQuotaMovementAt, now: currentDate)
        let hasRecentInteraction = isRecent(signals.lastInteractionAt, now: currentDate)

        var interval: TimeInterval
        var reason: AdaptiveRefreshReason
        if hasRecentMovement {
            interval = 60
            reason = .recentQuotaMovement
        } else if hasRecentInteraction {
            interval = 2 * 60
            reason = .recentInteraction
        } else {
            interval = 30 * 60
            reason = .idle
        }

        if signals.power.isOnBattery, interval < 10 * 60 {
            interval = 10 * 60
            reason = .batteryPower
        }
        if signals.power.isLowPowerModeEnabled, interval < 15 * 60 {
            interval = 15 * 60
            reason = .lowPowerMode
        }
        switch signals.power.thermalState {
        case .nominal:
            break
        case .fair:
            if interval < 15 * 60 {
                interval = 15 * 60
                reason = .thermalPressure
            }
        case .serious, .critical:
            if interval < 30 * 60 {
                interval = 30 * 60
            }
            reason = .thermalPressure
        }

        return AdaptiveRefreshDecision(interval: bounds.clamp(interval), reason: reason)
    }

    private func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date, date <= now else { return false }
        return now.timeIntervalSince(date) <= Self.activityWindow
    }
}

/// Comparable quota-only projection used to detect movement across refreshes.
/// New/disappearing windows are not treated as consumption; at least one
/// existing window's provider-reported `used` value must change.
nonisolated struct AdaptiveQuotaSnapshot: Equatable, Sendable {
    let values: [String: Double]

    func hasMovement(comparedTo other: AdaptiveQuotaSnapshot) -> Bool {
        let sharedKeys = Set(values.keys).intersection(other.values.keys)
        return sharedKeys.contains { values[$0] != other.values[$0] }
    }
}

nonisolated private enum SystemPowerSource {
    static var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }
            if state == kIOPSBatteryPowerValue as String {
                return true
            }
        }
        return false
    }
}
