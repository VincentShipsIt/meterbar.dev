import Combine
import Foundation

/// Owns the single prompt-once flag for MeterBar's first-launch experience.
/// Launch-at-login remains opt-in and is only registered after an explicit tap.
final class FirstRunOnboardingStore: ObservableObject {
    static let shared = FirstRunOnboardingStore()

    @Published private(set) var hasCompletedFirstRun: Bool

    private let userDefaults: UserDefaults
    private let launchAtLogin: LaunchAtLoginStore

    init(
        userDefaults: UserDefaults = .standard,
        launchAtLogin: LaunchAtLoginStore = .shared
    ) {
        self.userDefaults = userDefaults
        self.launchAtLogin = launchAtLogin
        if userDefaults.bool(forKey: StorageKeys.hasCompletedFirstRun) {
            hasCompletedFirstRun = true
        } else if Self.hasEvidenceOfPriorUse(in: userDefaults) {
            // Upgrades: installs that predate this flag already have other
            // MeterBar state persisted. Adopt the flag silently so long-time
            // users are never greeted with first-run onboarding.
            hasCompletedFirstRun = true
            userDefaults.set(true, forKey: StorageKeys.hasCompletedFirstRun)
        } else {
            hasCompletedFirstRun = false
        }
    }

    /// Keys a pre-onboarding install would have written during normal use.
    /// `cachedUsageMetrics` is persisted on every successful refresh, so any
    /// real install carries at least that one.
    private static let priorUseSentinelKeys: [String] = [
        StorageKeys.cachedUsageMetrics,
        StorageKeys.refreshInterval,
        StorageKeys.hiddenProviderServices,
        StorageKeys.notificationsEnabled,
        StorageKeys.claudeCodeCustomAccounts,
        StorageKeys.showInDock
    ]

    private static func hasEvidenceOfPriorUse(in userDefaults: UserDefaults) -> Bool {
        priorUseSentinelKeys.contains { userDefaults.object(forKey: $0) != nil }
    }

    var shouldPresent: Bool { !hasCompletedFirstRun }

    func chooseLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            launchAtLogin.setEnabled(true)
        }
        complete()
    }

    /// Clicking away is also a dismissal choice; onboarding must never nag on
    /// a later launch after the user has seen and dismissed it.
    func dismiss() {
        complete()
    }

    private func complete() {
        guard !hasCompletedFirstRun else { return }
        hasCompletedFirstRun = true
        userDefaults.set(true, forKey: StorageKeys.hasCompletedFirstRun)
    }
}
