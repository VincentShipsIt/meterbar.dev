import Foundation
import MeterBarShared

/// Minimal, side-effect-free input for the Stay Awake activation policy.
///
/// Manual mode treats the user's toggle as the signal that an agent is running.
/// The provider's tracked session window remains the safety gate: disabled,
/// missing, or depleted sessions cannot hold a power assertion.
nonisolated struct StayAwakeUsageSnapshot: Equatable, Sendable {
    let provider: ServiceType
    let isProviderEnabled: Bool
    let sessionUsedPercentage: Double?

    static func make(
        metrics: [ServiceType: UsageMetrics],
        enabledServices: Set<ServiceType>
    ) -> [StayAwakeUsageSnapshot] {
        metrics.map { provider, usage in
            StayAwakeUsageSnapshot(
                provider: provider,
                isProviderEnabled: enabledServices.contains(provider),
                sessionUsedPercentage: usage.sessionLimit?.percentage
            )
        }
        .sorted { $0.provider.sortOrder < $1.provider.sortOrder }
    }
}

nonisolated enum StayAwakeActivationDecision: Equatable, Sendable {
    case inactive
    case active(provider: ServiceType)
}

/// Pure policy for deciding whether MeterBar may hold a system-sleep assertion.
nonisolated enum StayAwakeActivationPolicy {
    static func decision(
        isManuallyEnabled: Bool,
        snapshots: [StayAwakeUsageSnapshot]
    ) -> StayAwakeActivationDecision {
        guard isManuallyEnabled else { return .inactive }

        let provider = snapshots
            .filter { snapshot in
                guard snapshot.isProviderEnabled,
                      snapshot.provider != .openRouter,
                      let used = snapshot.sessionUsedPercentage else {
                    return false
                }
                return used < 100
            }
            .min { $0.provider.sortOrder < $1.provider.sortOrder }?
            .provider

        guard let provider else { return .inactive }
        return .active(provider: provider)
    }
}
