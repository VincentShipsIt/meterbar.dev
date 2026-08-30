import Combine
import Foundation
import IOKit.pwr_mgt
import MeterBarShared
import os

/// Side-effect seam for the IOKit assertion. Tests use an in-memory conformer.
protocol PowerAssertionControlling: AnyObject {
    func acquire(for provider: ServiceType) -> Bool
    @discardableResult
    func release() -> Bool
}

/// Owns exactly one `PreventUserIdleSystemSleep` assertion.
final class IOKitPowerAssertionController: PowerAssertionControlling {
    private var assertionID: IOPMAssertionID?

    func acquire(for provider: ServiceType) -> Bool {
        if assertionID != nil {
            return true
        }

        var newAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName(for: provider) as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else {
            AppLog.app.error("Failed to create Stay Awake power assertion (IOKit result: \(result))")
            return false
        }

        assertionID = newAssertionID
        AppLog.app.info("Stay Awake power assertion acquired for \(provider.displayName, privacy: .public)")
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard let assertionID else { return true }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            AppLog.app.error("Failed to release Stay Awake power assertion (IOKit result: \(result))")
            return false
        }

        self.assertionID = nil
        AppLog.app.info("Stay Awake power assertion released")
        return true
    }

    static func assertionName(for provider: ServiceType) -> String {
        "MeterBar Stay Awake — \(provider.displayName)"
    }

    deinit {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
    }
}

/// Reconciles persisted manual intent and live usage into one IOKit assertion.
///
/// Reconciliation is idempotent. Switching providers releases the old
/// assertion before acquiring the replacement, and a failed release keeps the
/// held state visible so MeterBar never silently loses track of an assertion.
@MainActor
final class PowerAssertionManager: ObservableObject {
    static let shared = PowerAssertionManager()

    @Published private(set) var isAssertionHeld = false
    @Published private(set) var activeProvider: ServiceType?

    private let store: StayAwakeSettingsStore
    private let assertionController: PowerAssertionControlling
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    init(
        store: StayAwakeSettingsStore? = nil,
        assertionController: PowerAssertionControlling? = nil
    ) {
        self.store = store ?? .shared
        self.assertionController = assertionController ?? IOKitPowerAssertionController()
    }

    /// Starts observing the same metric and provider-visibility stores that
    /// drive the menu-bar cards. Safe to call more than once.
    func activate(
        dataManager: UsageDataManager? = nil,
        providerVisibility: ProviderVisibilityStore? = nil
    ) {
        guard !started else { return }
        started = true

        let dataManager = dataManager ?? .shared
        let providerVisibility = providerVisibility ?? .shared
        Publishers.CombineLatest3(
            store.$isEnabled,
            dataManager.$metrics,
            providerVisibility.$hiddenServices
        )
        .sink { [weak self] isEnabled, metrics, hiddenServices in
            guard let self else { return }
            let enabledServices = Set(ServiceType.allCases).subtracting(hiddenServices)
            let snapshots = StayAwakeUsageSnapshot.make(
                metrics: metrics,
                enabledServices: enabledServices
            )
            self.reconcile(isManuallyEnabled: isEnabled, snapshots: snapshots)
        }
        .store(in: &cancellables)
    }

    func reconcile(snapshots: [StayAwakeUsageSnapshot]) {
        reconcile(isManuallyEnabled: store.isEnabled, snapshots: snapshots)
    }

    /// App-termination hook. Persistent intent remains on for the next launch;
    /// only the process-owned assertion is released.
    func shutdown() {
        cancellables.removeAll()
        started = false
        releaseHeldAssertion()
    }

    private func reconcile(
        isManuallyEnabled: Bool,
        snapshots: [StayAwakeUsageSnapshot]
    ) {
        switch StayAwakeActivationPolicy.decision(
            isManuallyEnabled: isManuallyEnabled,
            snapshots: snapshots
        ) {
        case .inactive:
            releaseHeldAssertion()
        case .active(let provider):
            guard activeProvider != provider || !isAssertionHeld else { return }
            if isAssertionHeld, !releaseHeldAssertion() {
                return
            }
            guard assertionController.acquire(for: provider) else { return }
            activeProvider = provider
            isAssertionHeld = true
        }
    }

    @discardableResult
    private func releaseHeldAssertion() -> Bool {
        guard isAssertionHeld else { return true }
        guard assertionController.release() else { return false }
        activeProvider = nil
        isAssertionHeld = false
        return true
    }
}
